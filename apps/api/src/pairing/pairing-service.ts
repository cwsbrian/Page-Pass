import { createHash, createHmac, randomBytes, randomInt } from "node:crypto";

import type {
  ChildDeviceStatusReport,
  ChildDeviceStatusReportRequest,
  ChildSetupComplete,
  ChildSnapshot,
  ParentChildDevice,
  PairingConsume,
  PairingConsumeResponse,
  PairingSession
} from "../../../../libs/shared/src/index.js";
import { ApiError, type RequestIdentity, type StoreResult } from "../domain.js";
import { settleExpiredSession } from "../credit/credit-service.js";
import type { Prisma } from "../db/prisma.js";
import type { ParentUser } from "../family/family-service.js";

const pairingLifetimeMs = 5 * 60 * 1_000;
const numericAttemptWindowMs = 5 * 60 * 1_000;
const numericAttemptLimit = 5;
const targetNumericCodeStart = 900_000;
const numericCodeEnd = 1_000_000;
const maximumObservedAtFutureSkewMs = 30 * 1_000;
const maximumObservedAtAgeMs = 24 * 60 * 60 * 1_000;

export interface LegacyPairingStore {
  consumePairing(
    input: PairingConsume,
    identity: RequestIdentity
  ): StoreResult<PairingConsumeResponse>;
  snapshot(deviceCredential: string | undefined): StoreResult<ChildSnapshot>;
}

export interface PairingServiceOptions {
  pepper: string | Buffer;
  now?: () => number;
  legacy?: LegacyPairingStore;
}

export interface PairingApi {
  consume(
    input: PairingConsume,
    identity: RequestIdentity
  ): Promise<PairingConsumeResponse>;
  snapshot(deviceCredential: string | undefined): Promise<ChildSnapshot>;
  completeSetup(
    deviceCredential: string | undefined,
    input: ChildSetupComplete
  ): Promise<ChildSnapshot>;
  reportStatus(
    deviceCredential: string | undefined,
    input: ChildDeviceStatusReportRequest
  ): Promise<ChildDeviceStatusReport>;
}

export class PrismaPairingService implements PairingApi {
  private readonly pepper: Buffer;
  private readonly now: () => number;

  constructor(
    private readonly prisma: Prisma,
    private readonly options: PairingServiceOptions
  ) {
    this.pepper = Buffer.isBuffer(options.pepper)
      ? Buffer.from(options.pepper)
      : Buffer.from(options.pepper, "utf8");
    this.now = options.now ?? Date.now;
  }

  async createSession(
    parent: ParentUser,
    childProfileId: string
  ): Promise<PairingSession> {
    const qrToken = randomBytes(32).toString("base64url");
    const expiresAt = new Date(this.now() + pairingLifetimeMs);

    const created = await this.prisma.$transaction(async (transaction) => {
      await transaction.$executeRaw`
        SELECT pg_advisory_xact_lock(
          hashtextextended(${"pairing-child:" + childProfileId}, 0)
        )
      `;
      const child = await transaction.childProfile.findFirst({
        where: {
          id: childProfileId,
          status: "active",
          family: {
            status: "active",
            members: {
              some: {
                userId: parent.id,
                status: "active"
              }
            }
          }
        },
        select: {
          id: true,
          devices: {
            where: { status: "active" },
            orderBy: [{ pairedAt: "desc" }, { id: "desc" }],
            select: { id: true },
            take: 1
          }
        }
      });
      if (child === null) {
        throw new ApiError(404, "child_not_found", "The child profile does not exist");
      }

      const createdAt = new Date(this.now());
      await transaction.pairingSession.updateMany({
        where: {
          childProfileId,
          invalidatedAt: null,
          consumedAt: null
        },
        data: { invalidatedAt: createdAt }
      });
      await transaction.$executeRaw`
        SELECT pg_advisory_xact_lock(
          hashtextextended(${"pairing-code-allocation:v2"}, 0)
        )
      `;
      await transaction.pairingSession.updateMany({
        where: {
          expiresAt: { lte: createdAt },
          invalidatedAt: null,
          consumedAt: null
        },
        data: { invalidatedAt: createdAt }
      });
      let numericCode: string | undefined;
      for (let attempt = 0; attempt < 20; attempt += 1) {
        const candidate = randomInt(
          targetNumericCodeStart,
          numericCodeEnd
        ).toString();
        const collision = await transaction.pairingSession.findFirst({
          where: {
            numericCodeDigest: this.hash("pairing-code", candidate),
            invalidatedAt: null,
            consumedAt: null
          },
          select: { id: true }
        });
        if (collision === null) {
          numericCode = candidate;
          break;
        }
      }
      if (numericCode === undefined) {
        throw new ApiError(
          503,
          "pairing_code_unavailable",
          "A pairing code could not be allocated; try again"
        );
      }
      const replacedDevice = child.devices[0];
      const session = await transaction.pairingSession.create({
        data: {
          childProfileId,
          createdByUserId: parent.id,
          purpose: replacedDevice === undefined ? "add_device" : "replace_device",
          replacesDeviceId: replacedDevice?.id,
          qrTokenDigest: this.hash("pairing-token", qrToken),
          numericCodeDigest: this.hash("pairing-code", numericCode),
          expiresAt,
          createdAt
        }
      });
      return { session, numericCode };
    });

    return {
      id: created.session.id,
      childProfileId: created.session.childProfileId,
      qrToken,
      numericCode: created.numericCode,
      expiresAt: created.session.expiresAt.toISOString()
    };
  }

  async listDevices(
    parent: ParentUser,
    childProfileId: string
  ): Promise<ParentChildDevice[]> {
    const child = await this.prisma.childProfile.findFirst({
      where: {
        id: childProfileId,
        status: "active",
        family: {
          status: "active",
          members: {
            some: {
              userId: parent.id,
              status: "active"
            }
          }
        }
      },
      select: {
        devices: {
          orderBy: [{ pairedAt: "desc" }, { id: "desc" }],
          include: {
            statusReports: {
              orderBy: [{ observedAt: "desc" }, { receivedAt: "desc" }],
              take: 1
            }
          }
        }
      }
    });
    if (child === null) {
      throw new ApiError(404, "child_not_found", "The child profile does not exist");
    }
    return child.devices.map((device) => {
      const latestStatus = device.statusReports[0];
      return {
        id: device.id,
        childProfileId: device.childProfileId,
        deviceName: device.deviceName,
        platform: device.platform,
        status: device.status as ParentChildDevice["status"],
        appVersion: device.appVersion,
        appBuild: device.appBuild,
        pairedAt: device.pairedAt.toISOString(),
        ...(device.readyAt === null ? {} : { readyAt: device.readyAt.toISOString() }),
        ...(device.retiredAt === null
          ? {}
          : { retiredAt: device.retiredAt.toISOString() }),
        ...(device.revokedAt === null
          ? {}
          : { revokedAt: device.revokedAt.toISOString() }),
        ...(device.lastSeenAt === null
          ? {}
          : { lastSeenAt: device.lastSeenAt.toISOString() }),
        ...(latestStatus === undefined
          ? {}
          : { latestStatus: publicDeviceStatusReport(latestStatus) })
      };
    });
  }

  async revokeDevice(
    parent: ParentUser,
    childProfileId: string,
    deviceId: string
  ): Promise<void> {
    await this.prisma.$transaction(async (transaction) => {
      await transaction.$executeRaw`
        SELECT pg_advisory_xact_lock(
          hashtextextended(${"pairing-child:" + childProfileId}, 0)
        )
      `;
      await transaction.$executeRaw`
        SELECT pg_advisory_xact_lock(
          hashtextextended(${"app-policy:" + childProfileId}, 0)
        )
      `;
      await transaction.$executeRaw`
        SELECT pg_advisory_xact_lock(
          hashtextextended(${"credit-child:" + childProfileId}, 0)
        )
      `;
      const device = await transaction.device.findFirst({
        where: {
          id: deviceId,
          childProfileId,
          childProfile: {
            status: "active",
            family: {
              status: "active",
              members: {
                some: {
                  userId: parent.id,
                  status: "active"
                }
              }
            }
          }
        },
        select: { id: true, status: true }
      });
      if (device === null) {
        throw new ApiError(404, "device_not_found", "The child device does not exist");
      }
      if (device.status === "revoked") return;

      const unsettledSession = await transaction.earnedTimeSession.findFirst({
        where: {
          deviceId,
          state: { in: ["prepared", "active", "settlement_pending"] }
        },
        select: { id: true }
      });
      if (unsettledSession !== null) {
        throw new ApiError(
          409,
          "active_session_exists",
          "Stop and sync Earned Time before revoking this device"
        );
      }

      const now = new Date(this.now());
      await transaction.managedApp.updateMany({
        where: {
          childProfileId,
          sourceDeviceId: deviceId,
          archivedAt: null
        },
        data: { archivedAt: now }
      });
      await transaction.appRequest.updateMany({
        where: {
          childProfileId,
          requestedByDeviceId: deviceId,
          status: "pending"
        },
        data: {
          status: "decided",
          requestVersion: { increment: 1 },
          decision: null,
          decidedAt: now
        }
      });
      await transaction.device.update({
        where: { id: deviceId },
        data: {
          status: "revoked",
          revokedAt: now
        }
      });
      await transaction.deviceCredential.updateMany({
        where: { deviceId, revokedAt: null },
        data: { revokedAt: now }
      });
      await transaction.childPushDevice.updateMany({
        where: { deviceId, revokedAt: null },
        data: { revokedAt: now }
      });
    });
  }

  async consume(
    input: PairingConsume,
    identity: RequestIdentity
  ): Promise<PairingConsumeResponse> {
    if (
      input.numericCode !== undefined &&
      Number(input.numericCode) < targetNumericCodeStart
    ) {
      if (this.options.legacy !== undefined) {
        return this.options.legacy.consumePairing(input, identity);
      }
      throw new ApiError(
        401,
        "invalid_pairing_secret",
        "The pairing token or code is invalid"
      );
    }
    const target = await this.consumeTarget(input, identity);
    if (target !== undefined) return target;
    if (input.qrToken !== undefined && this.options.legacy !== undefined) {
      return this.options.legacy.consumePairing(input, identity);
    }
    throw new ApiError(
      401,
      "invalid_pairing_secret",
      "The pairing token or code is invalid"
    );
  }

  async snapshot(deviceCredential: string | undefined): Promise<ChildSnapshot> {
    if (deviceCredential === undefined) {
      throw new ApiError(
        401,
        "unauthorized",
        "A child device bearer token is required"
      );
    }
    const target = await this.snapshotTarget(deviceCredential);
    if (target !== undefined) return target;
    if (this.options.legacy !== undefined) {
      return this.options.legacy.snapshot(deviceCredential);
    }
    throw new ApiError(
      401,
      "unauthorized",
      "The child device bearer token is invalid or revoked"
    );
  }

  async completeSetup(
    deviceCredential: string | undefined,
    input: ChildSetupComplete
  ): Promise<ChildSnapshot> {
    if (deviceCredential === undefined) {
      throw new ApiError(
        401,
        "unauthorized",
        "A child device bearer token is required"
      );
    }
    const digest = this.hash("child-credential", deviceCredential);
    const activated = await this.prisma.$transaction(async (transaction) => {
      const candidate = await transaction.deviceCredential.findUnique({
        where: { tokenDigest: digest },
        include: {
          device: {
            select: { id: true, childProfileId: true }
          }
        }
      });
      if (candidate === null) return false;

      await transaction.$executeRaw`
        SELECT pg_advisory_xact_lock(
          hashtextextended(
            ${"pairing-child:" + candidate.device.childProfileId},
            0
          )
        )
      `;
      await transaction.$executeRaw`
        SELECT pg_advisory_xact_lock(
          hashtextextended(
            ${"app-policy:" + candidate.device.childProfileId},
            0
          )
        )
      `;
      await transaction.$executeRaw`
        SELECT pg_advisory_xact_lock(
          hashtextextended(
            ${"credit-child:" + candidate.device.childProfileId},
            0
          )
        )
      `;
      await transaction.$queryRaw`
        SELECT id
        FROM devices
        WHERE id = ${candidate.deviceId}::uuid
        FOR UPDATE
      `;
      await transaction.$queryRaw`
        SELECT id
        FROM device_credentials
        WHERE id = ${candidate.id}::uuid
        FOR UPDATE
      `;
      await transaction.$queryRaw`
        SELECT id
        FROM devices
        WHERE child_profile_id = ${candidate.device.childProfileId}::uuid
          AND status = 'active'
        ORDER BY id
        FOR UPDATE
      `;
      await transaction.$queryRaw`
        SELECT dc.id
        FROM device_credentials dc
        JOIN devices d ON d.id = dc.device_id
        WHERE d.child_profile_id = ${candidate.device.childProfileId}::uuid
          AND d.status = 'active'
          AND dc.revoked_at IS NULL
        ORDER BY dc.id
        FOR UPDATE OF dc
      `;
      const credential = await transaction.deviceCredential.findUniqueOrThrow({
        where: { id: candidate.id },
        include: {
          device: {
            include: {
              childProfile: { select: { status: true } }
            }
          }
        }
      });
      const now = new Date(this.now());
      throwIfCredentialWasDisconnected(credential);
      if (
        (credential.expiresAt !== null && now >= credential.expiresAt) ||
        !["pending_setup", "active"].includes(credential.device.status) ||
        credential.device.childProfile.status !== "active"
      ) {
        throw new ApiError(
          401,
          "unauthorized",
          "The child device bearer token is invalid or revoked"
        );
      }

      const managedAppCount = await transaction.managedApp.count({
        where: {
          childProfileId: credential.device.childProfileId,
          sourceDeviceId: credential.deviceId,
          archivedAt: null
        }
      });
      const latestPolicy = await transaction.childPolicyVersion.findFirst({
        where: { childProfileId: credential.device.childProfileId },
        orderBy: { version: "desc" },
        select: { version: true }
      });
      const policyAck = latestPolicy === null
        ? null
        : await transaction.policyApplicationAck.findUnique({
            where: {
              deviceId_policyVersion: {
                deviceId: credential.deviceId,
                policyVersion: latestPolicy.version
              }
            },
            select: { result: true }
          });
      if (
        managedAppCount === 0 ||
        managedAppCount !== input.earnedTimeAppCount ||
        latestPolicy === null ||
        policyAck?.result !== "applied"
      ) {
        throw new ApiError(
          409,
          "setup_policy_not_applied",
          "Managed apps must be locked and the latest policy acknowledged before setup"
        );
      }

      if (credential.device.status === "pending_setup") {
        const unsettled = await transaction.earnedTimeSession.findFirst({
          where: {
            childProfileId: credential.device.childProfileId,
            state: { in: ["prepared", "active", "settlement_pending"] }
          }
        });
        if (
          ["active", "settlement_pending"].includes(unsettled?.state ?? "") &&
          unsettled !== null &&
          now < unsettled.expiresAt
        ) {
          throw new ApiError(
            409,
            "active_session_exists",
            "Finish the active Earned Time session before replacing this device"
          );
        }
        if (unsettled?.state === "prepared") {
          await transaction.earnedTimeSession.update({
            where: { id: unsettled.id },
            data: {
              state: "cancelled",
              endedAt: now,
              consumedSeconds: 0,
              balanceAfterSeconds: unsettled.balanceBeforeSeconds,
              endReason: "recovery",
              settledAt: now,
              updatedAt: now
            }
          });
        } else if (
          unsettled !== null &&
          ["active", "settlement_pending"].includes(unsettled.state)
        ) {
          await settleExpiredSession(transaction, unsettled, now);
        }
        const replaced = await transaction.device.findMany({
          where: {
            childProfileId: credential.device.childProfileId,
            status: "active",
            id: { not: credential.deviceId }
          },
          select: { id: true }
        });
        if (replaced.length > 0) {
          const replacedIds = replaced.map((device) => device.id);
          await transaction.managedApp.updateMany({
            where: {
              childProfileId: credential.device.childProfileId,
              sourceDeviceId: { in: replacedIds },
              archivedAt: null
            },
            data: { archivedAt: now }
          });
          await transaction.appRequest.updateMany({
            where: {
              childProfileId: credential.device.childProfileId,
              requestedByDeviceId: { in: replacedIds },
              status: "pending"
            },
            data: {
              status: "decided",
              requestVersion: { increment: 1 },
              decision: "denied",
              decidedAt: now
            }
          });
          await transaction.device.updateMany({
            where: { id: { in: replacedIds } },
            data: { status: "retired", retiredAt: now }
          });
          await transaction.deviceCredential.updateMany({
            where: { deviceId: { in: replacedIds }, revokedAt: null },
            data: { revokedAt: now }
          });
        }
        await transaction.device.update({
          where: { id: credential.deviceId },
          data: {
            status: "active",
            readyAt: now,
            lastSeenAt: now
          }
        });
      } else {
        await transaction.device.update({
          where: { id: credential.deviceId },
          data: { lastSeenAt: now }
        });
      }
      await transaction.deviceCredential.update({
        where: { id: credential.id },
        data: { lastUsedAt: now }
      });
      return true;
    });
    if (!activated) {
      throw new ApiError(
        401,
        "unauthorized",
        "The child device bearer token is invalid or revoked"
      );
    }
    return this.snapshot(deviceCredential);
  }

  async reportStatus(
    deviceCredential: string | undefined,
    input: ChildDeviceStatusReportRequest
  ): Promise<ChildDeviceStatusReport> {
    if (deviceCredential === undefined) {
      throw new ApiError(
        401,
        "unauthorized",
        "A child device bearer token is required"
      );
    }
    const now = new Date(this.now());
    const observedAt = new Date(input.observedAt);
    if (observedAt.getTime() > now.getTime() + maximumObservedAtFutureSkewMs) {
      throw new ApiError(
        400,
        "observed_at_in_future",
        "The device observation time is too far in the future"
      );
    }
    if (observedAt.getTime() < now.getTime() - maximumObservedAtAgeMs) {
      throw new ApiError(
        400,
        "observed_at_too_old",
        "The device observation time is too old"
      );
    }
    const policyAppliedAt = input.policyApplication === undefined
      ? undefined
      : new Date(input.policyApplication.appliedAt);
    if (
      policyAppliedAt !== undefined &&
      policyAppliedAt.getTime() >
        observedAt.getTime() + maximumObservedAtFutureSkewMs
    ) {
      throw new ApiError(
        400,
        "policy_application_after_observation",
        "The policy application time cannot be after the observation"
      );
    }
    const requestFingerprint = deviceStatusRequestFingerprint(input);

    const digest = this.hash("child-credential", deviceCredential);
    const report = await this.prisma.$transaction(async (transaction) => {
      const credential = await transaction.deviceCredential.findUnique({
        where: { tokenDigest: digest },
        include: {
          device: {
            include: {
              childProfile: { select: { status: true } }
            }
          }
        }
      });
      if (credential === null) {
        throw new ApiError(
          401,
          "unauthorized",
          "The child device bearer token is invalid or revoked"
        );
      }
      throwIfCredentialWasDisconnected(credential);
      if (
        (credential.expiresAt !== null && now >= credential.expiresAt) ||
        !["pending_setup", "active"].includes(credential.device.status) ||
        credential.device.childProfile.status !== "active"
      ) {
        throw new ApiError(
          401,
          "unauthorized",
          "The child device bearer token is invalid or revoked"
        );
      }

      const latestPolicy = await transaction.childPolicyVersion.findFirst({
        where: { childProfileId: credential.device.childProfileId },
        orderBy: { version: "desc" },
        select: { version: true }
      });
      const latestPolicyVersion = latestPolicy?.version ?? 0n;
      if (BigInt(input.lastAppliedPolicyVersion) > latestPolicyVersion) {
        throw new ApiError(
          409,
          "policy_version_ahead",
          "The reported policy version is ahead of the server policy"
        );
      }
      if (
        input.policyApplication !== undefined &&
        BigInt(input.policyApplication.policyVersion) > latestPolicyVersion
      ) {
        throw new ApiError(
          409,
          "policy_version_ahead",
          "The policy application version is ahead of the server policy"
        );
      }

      await transaction.$executeRaw`
        SELECT pg_advisory_xact_lock(
          hashtextextended(
            ${`device-status:${credential.deviceId}:${observedAt.toISOString()}`},
            0
          )
        )
      `;
      const existing = await transaction.deviceStatusReport.findUnique({
        where: {
          deviceId_observedAt: { deviceId: credential.deviceId, observedAt }
        }
      });
      if (
        existing !== null &&
        existing.requestFingerprint !== requestFingerprint
      ) {
        throw new ApiError(
          409,
          "status_report_conflict",
          "A different status report already exists for this observation time"
        );
      }
      const saved = existing ?? await transaction.deviceStatusReport.create({
        data: {
          deviceId: credential.deviceId,
          observedAt,
          authorizationStatus: input.authorizationStatus,
          managedAppCount: input.managedAppCount,
          controlStatus: input.controlStatus,
          lastAppliedPolicyVersion: input.lastAppliedPolicyVersion,
          policyApplicationResult: input.policyApplication?.result,
          policyApplicationVersion: input.policyApplication?.policyVersion,
          policyAppliedAt,
          pendingSettlementCount: input.pendingSettlementCount,
          requestFingerprint,
          receivedAt: now
        }
      });
      await transaction.device.update({
        where: { id: credential.deviceId },
        data: {
          appVersion: input.appVersion,
          appBuild: input.appBuild,
          lastSeenAt: now
        }
      });
      await transaction.deviceCredential.update({
        where: { id: credential.id },
        data: { lastUsedAt: now }
      });
      return saved;
    });
    return publicDeviceStatusReport(report);
  }

  private async consumeTarget(
    input: PairingConsume,
    identity: RequestIdentity
  ): Promise<PairingConsumeResponse | undefined> {
    const isNumeric = input.numericCode !== undefined;
    const secret = input.numericCode ?? input.qrToken!;
    const digest = this.hash(
      isNumeric ? "pairing-code" : "pairing-token",
      secret
    );
    const lockKey = `pairing-secret:${digest.toString("hex")}`;

    return this.prisma.$transaction(async (transaction) => {
      await transaction.$executeRaw`
        SELECT pg_advisory_xact_lock(hashtextextended(${lockKey}, 0))
      `;
      if (isNumeric) {
        await this.recordNumericAttempt(
          transaction,
          input.installationId,
          identity.remoteAddress
        );
      }
      const candidate = await transaction.pairingSession.findFirst({
        where: isNumeric
          ? { numericCodeDigest: digest }
          : { qrTokenDigest: digest },
        orderBy: { createdAt: "desc" },
        select: { id: true, childProfileId: true }
      });
      if (candidate === null) return undefined;
      await transaction.$executeRaw`
        SELECT pg_advisory_xact_lock(
          hashtextextended(
            ${"pairing-child:" + candidate.childProfileId},
            0
          )
        )
      `;
      await transaction.$executeRaw`
        SELECT pg_advisory_xact_lock(
          hashtextextended(${"pairing-session:" + candidate.id}, 0)
        )
      `;
      const session = await transaction.pairingSession.findUniqueOrThrow({
        where: { id: candidate.id },
        include: {
          childProfile: {
            select: {
              id: true,
              name: true,
              status: true,
              creditBalance: true
            }
          }
        }
      });
      if (session.invalidatedAt !== null) {
        throw new ApiError(
          409,
          "pairing_session_invalidated",
          "The pairing session has been replaced"
        );
      }
      if (session.consumedAt !== null) {
        throw new ApiError(
          409,
          "pairing_session_consumed",
          "The pairing session has already been used"
        );
      }
      const now = new Date(this.now());
      if (now >= session.expiresAt) {
        throw new ApiError(
          410,
          "pairing_session_expired",
          "The pairing session has expired"
        );
      }
      if (session.childProfile.status !== "active") {
        throw new ApiError(404, "child_not_found", "The child profile does not exist");
      }
      if (session.childProfile.creditBalance === null) {
        throw new Error("Child credit balance is missing");
      }

      await transaction.$executeRaw`
        SELECT pg_advisory_xact_lock(
          hashtextextended(
            ${"app-policy:" + session.childProfileId},
            0
          )
        )
      `;
      const installationDevice = await transaction.device.findUnique({
        where: { installationId: input.installationId },
        select: { id: true, childProfileId: true, status: true }
      });
      if (
        installationDevice !== null &&
        installationDevice.childProfileId !== session.childProfileId
      ) {
        throw new ApiError(
          409,
          "installation_already_bound",
          "This installation is already paired to a different child profile"
        );
      }
      const preservesActiveSetup = installationDevice?.status === "active";
      if (preservesActiveSetup) {
        await transaction.$executeRaw`
          SELECT pg_advisory_xact_lock(
            hashtextextended(
              ${"credit-child:" + session.childProfileId},
              0
            )
          )
        `;
        await transaction.$queryRaw`
          SELECT id
          FROM devices
          WHERE id = ${installationDevice.id}::uuid
          FOR UPDATE
        `;
        const unsettledSession = await transaction.earnedTimeSession.findFirst({
          where: {
            childProfileId: session.childProfileId,
            state: { in: ["prepared", "active", "settlement_pending"] }
          },
          select: { id: true }
        });
        if (unsettledSession !== null) {
          throw new ApiError(
            409,
            "active_session_exists",
            "Finish the Earned Time session before pairing this installation again"
          );
        }
      }

      const appVersion = input.appVersion ?? "unknown";
      const appBuild = input.appBuild ?? "unknown";
      const stalePendingDevices = await transaction.device.findMany({
        where: {
          childProfileId: session.childProfileId,
          status: "pending_setup",
          installationId: { not: input.installationId }
        },
        select: { id: true }
      });
      if (stalePendingDevices.length > 0) {
        const staleDeviceIds = stalePendingDevices.map((device) => device.id);
        await transaction.device.updateMany({
          where: { id: { in: staleDeviceIds } },
          data: {
            status: "revoked",
            revokedAt: now
          }
        });
        await transaction.deviceCredential.updateMany({
          where: {
            deviceId: { in: staleDeviceIds },
            revokedAt: null
          },
          data: { revokedAt: now }
        });
      }
      const device = installationDevice === null
        ? await transaction.device.create({
            data: {
              childProfileId: session.childProfileId,
              installationId: input.installationId,
              deviceName: input.deviceName,
              appVersion,
              appBuild,
              pairedAt: now
            }
          })
        : await transaction.device.update({
            where: { id: installationDevice.id },
            data: {
              deviceName: input.deviceName,
              status: preservesActiveSetup ? "active" : "pending_setup",
              appVersion,
              appBuild,
              pairedAt: now,
              readyAt: preservesActiveSetup ? undefined : null,
              retiredAt: null,
              revokedAt: null
            }
          });

      if (installationDevice !== null && !preservesActiveSetup) {
        await transaction.managedApp.updateMany({
          where: {
            childProfileId: session.childProfileId,
            sourceDeviceId: installationDevice.id,
            archivedAt: null
          },
          data: { archivedAt: now }
        });
        await transaction.appRequest.updateMany({
          where: {
            childProfileId: session.childProfileId,
            requestedByDeviceId: installationDevice.id,
            status: "pending"
          },
          data: {
            status: "decided",
            requestVersion: { increment: 1 },
            decision: "denied",
            decidedAt: now
          }
        });
      }
      await transaction.deviceCredential.updateMany({
        where: { deviceId: device.id, revokedAt: null },
        data: { revokedAt: now }
      });
      const deviceCredential = randomBytes(32).toString("base64url");
      await transaction.deviceCredential.create({
        data: {
          deviceId: device.id,
          tokenDigest: this.hash("child-credential", deviceCredential),
          createdAt: now
        }
      });
      await transaction.pairingSession.update({
        where: { id: session.id },
        data: {
          consumedAt: now,
          consumedByDeviceId: device.id
        }
      });

      return {
        deviceCredential,
        child: {
          id: session.childProfile.id,
          name: session.childProfile.name,
          balanceSeconds: safeCreditNumber(
            session.childProfile.creditBalance.balanceSeconds
          )
        }
      };
    });
  }

  private async snapshotTarget(
    deviceCredential: string
  ): Promise<ChildSnapshot | undefined> {
    const digest = this.hash("child-credential", deviceCredential);
    const now = new Date(this.now());
    return this.prisma.$transaction(async (transaction) => {
      const credential = await transaction.deviceCredential.findUnique({
        where: { tokenDigest: digest },
        include: {
          device: {
            include: {
              childProfile: {
                select: {
                  id: true,
                  name: true,
                  status: true,
                  creditBalance: true,
                  family: {
                    select: {
                      preferences: {
                        select: { sessionPresetSeconds: true }
                      }
                    }
                  }
                }
              }
            }
          }
        }
      });
      if (credential === null) return undefined;
      throwIfCredentialWasDisconnected(credential);
      if (
        (credential.expiresAt !== null && now >= credential.expiresAt) ||
        !["pending_setup", "active"].includes(credential.device.status) ||
        credential.device.childProfile.status !== "active"
      ) {
        throw new ApiError(
          401,
          "unauthorized",
          "The child device bearer token is invalid or revoked"
        );
      }
      if (credential.device.childProfile.creditBalance === null) {
        throw new Error("Child credit balance is missing");
      }

      await transaction.device.update({
        where: { id: credential.deviceId },
        data: { lastSeenAt: now }
      });
      await transaction.deviceCredential.update({
        where: { id: credential.id },
        data: { lastUsedAt: now }
      });
      const state = await transaction.serverState.findUnique({
        where: { singleton: true },
        select: { ledgerRevision: true, serverInstanceId: true }
      });
      if (state === null) {
        throw new Error("PagePass server state is missing");
      }
      const policy = await transaction.childPolicyVersion.findFirst({
        where: {
          childProfileId: credential.device.childProfile.id
        },
        orderBy: { version: "desc" },
        select: { version: true }
      });

      const timestamp = now.toISOString();
      return {
        childProfileId: credential.device.childProfile.id,
        childName: credential.device.childProfile.name,
        deviceStatus: credential.device.status as "pending_setup" | "active",
        balanceSeconds: safeCreditNumber(
          credential.device.childProfile.creditBalance.balanceSeconds
        ),
        policyVersion: safeCreditNumber(policy?.version ?? 0n),
        ledgerRevision: safeCreditNumber(
          credential.device.childProfile.creditBalance.ledgerRevision
        ),
        sessionPresetSeconds:
          credential.device.childProfile.family.preferences
            ?.sessionPresetSeconds as ChildSnapshot["sessionPresetSeconds"]
          ?? [900, 1_800, 3_600],
        serverInstanceId: state.serverInstanceId,
        serverTime: timestamp,
        lastSyncedAt: timestamp
      };
    });
  }

  private async recordNumericAttempt(
    transaction: Pick<Prisma, "$executeRaw" | "pairingRateAttempt">,
    installationId: string,
    remoteAddress: string
  ): Promise<void> {
    const installationHash = this.hash(
      "rate-limit-installation",
      installationId
    );
    const addressHash = this.hash("rate-limit-address", remoteAddress);
    const lockKeys = [
      `installation:${installationHash.toString("hex")}`,
      `address:${addressHash.toString("hex")}`
    ].sort();
    for (const lockKey of lockKeys) {
      await transaction.$executeRaw`
        SELECT pg_advisory_xact_lock(hashtextextended(${lockKey}, 0))
      `;
    }

    const oldestAllowed = new Date(this.now() - numericAttemptWindowMs);
    await transaction.pairingRateAttempt.deleteMany({
      where: {
        attemptedAt: { lt: oldestAllowed },
        OR: [
          { dimension: "installation", keyHash: installationHash },
          { dimension: "address", keyHash: addressHash }
        ]
      }
    });
    const counts = await transaction.pairingRateAttempt.groupBy({
      by: ["dimension"],
      where: {
        OR: [
          { dimension: "installation", keyHash: installationHash },
          { dimension: "address", keyHash: addressHash }
        ]
      },
      _count: true
    });
    if (counts.some((row) => row._count >= numericAttemptLimit)) {
      throw new ApiError(
        429,
        "pairing_rate_limited",
        "Too many numeric pairing attempts; try again later"
      );
    }
    const attemptedAt = new Date(this.now());
    await transaction.pairingRateAttempt.createMany({
      data: [
        {
          dimension: "installation",
          keyHash: installationHash,
          attemptedAt
        },
        {
          dimension: "address",
          keyHash: addressHash,
          attemptedAt
        }
      ]
    });
  }

  private hash(purpose: string, value: string): Buffer {
    return createHmac("sha256", this.pepper)
      .update(purpose)
      .update("\0")
      .update(value)
      .digest();
  }
}

function safeCreditNumber(value: bigint): number {
  if (value < 0n || value > BigInt(Number.MAX_SAFE_INTEGER)) {
    throw new Error("Stored credit value is outside the supported range");
  }
  return Number(value);
}

function throwIfCredentialWasDisconnected(credential: {
  revokedAt: Date | null;
  device: {
    status: string;
    childProfile: { status: string };
  };
}): void {
  if (credential.device.childProfile.status === "archived") {
    throw new ApiError(
      401,
      "child_archived",
      "The child profile was archived"
    );
  }
  if (
    credential.revokedAt !== null ||
    ["revoked", "replaced"].includes(credential.device.status)
  ) {
    throw new ApiError(
      401,
      "device_revoked",
      "A parent disconnected this device from PagePass"
    );
  }
}

function publicDeviceStatusReport(report: {
  id: string;
  observedAt: Date;
  authorizationStatus: string;
  managedAppCount: number;
  controlStatus: string;
  lastAppliedPolicyVersion: bigint;
  policyApplicationResult: string | null;
  policyApplicationVersion: bigint | null;
  policyAppliedAt: Date | null;
  pendingSettlementCount: number;
  receivedAt: Date;
}): ChildDeviceStatusReport {
  const hasPolicyApplication = report.policyApplicationResult !== null &&
    report.policyApplicationVersion !== null &&
    report.policyAppliedAt !== null;
  return {
    id: report.id,
    observedAt: report.observedAt.toISOString(),
    authorizationStatus:
      report.authorizationStatus as ChildDeviceStatusReport["authorizationStatus"],
    managedAppCount: report.managedAppCount,
    controlStatus:
      report.controlStatus as ChildDeviceStatusReport["controlStatus"],
    lastAppliedPolicyVersion: safeCreditNumber(
      report.lastAppliedPolicyVersion
    ),
    ...(hasPolicyApplication
      ? {
          policyApplication: {
            result: report.policyApplicationResult as "applied" | "failed",
            policyVersion: safeCreditNumber(
              report.policyApplicationVersion!
            ),
            appliedAt: report.policyAppliedAt!.toISOString()
          }
        }
      : {}),
    pendingSettlementCount: report.pendingSettlementCount,
    receivedAt: report.receivedAt.toISOString()
  };
}

function deviceStatusRequestFingerprint(
  input: ChildDeviceStatusReportRequest
): string {
  return createHash("sha256").update(JSON.stringify({
    observedAt: input.observedAt,
    appVersion: input.appVersion,
    appBuild: input.appBuild,
    authorizationStatus: input.authorizationStatus,
    managedAppCount: input.managedAppCount,
    controlStatus: input.controlStatus,
    lastAppliedPolicyVersion: input.lastAppliedPolicyVersion,
    policyApplication: input.policyApplication ?? null,
    pendingSettlementCount: input.pendingSettlementCount
  })).digest("hex");
}
