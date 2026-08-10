import {
  createCipheriv,
  createDecipheriv,
  createHmac,
  randomBytes,
  timingSafeEqual
} from "node:crypto";

import type {
  AppAccessResponse,
  AppPolicyUpdate,
  AppRequestCreate,
  AppRequestDecision,
  ManagedAppPolicy,
  ManagedAppRegistration,
  PolicyAck
} from "../../../../libs/shared/src/index.js";
import { ApiError, stableFingerprint } from "../domain.js";
import type { Prisma } from "../db/prisma.js";
import type { ParentUser } from "../family/family-service.js";

const envelopeCipherVersion = 1;
const envelopeIVBytes = 12;
const envelopeTagBytes = 16;
const maximumDecodedEnvelopeBytes = 16 * 1_024;

export interface AppAccessApi {
  register(
    deviceCredential: string | undefined,
    input: ManagedAppRegistration
  ): Promise<AppAccessResponse>;
  childAccess(
    deviceCredential: string | undefined
  ): Promise<AppAccessResponse>;
  createRequest(
    deviceCredential: string | undefined,
    input: AppRequestCreate
  ): Promise<AppAccessResponse>;
  parentAccess(
    parent: ParentUser,
    childProfileId: string
  ): Promise<AppAccessResponse>;
  decideRequest(
    parent: ParentUser,
    requestId: string,
    input: AppRequestDecision
  ): Promise<AppAccessResponse>;
  updatePolicy(
    parent: ParentUser,
    childProfileId: string,
    managedAppId: string,
    input: AppPolicyUpdate
  ): Promise<AppAccessResponse>;
  acknowledge(
    deviceCredential: string | undefined,
    input: PolicyAck
  ): Promise<AppAccessResponse>;
}

export interface AppAccessServiceOptions {
  pepper: string | Buffer;
  now?: () => number;
}

export class PrismaAppAccessService implements AppAccessApi {
  private readonly pepper: Buffer;
  private readonly encryptionKey: Buffer;
  private readonly now: () => number;

  constructor(
    private readonly prisma: Prisma,
    options: AppAccessServiceOptions
  ) {
    this.pepper = Buffer.isBuffer(options.pepper)
      ? Buffer.from(options.pepper)
      : Buffer.from(options.pepper, "utf8");
    this.encryptionKey = createHmac("sha256", this.pepper)
      .update("managed-app-token-envelope-key:v1")
      .digest();
    this.now = options.now ?? Date.now;
  }

  async register(
    deviceCredential: string | undefined,
    input: ManagedAppRegistration
  ): Promise<AppAccessResponse> {
    const prepared = input.apps.map((app) => {
      validateTokenEnvelope(app.tokenEnvelope);
      return {
        ...app,
        digest: this.hash("managed-app-token", app.tokenEnvelope)
      };
    });
    if (
      new Set(prepared.map((app) => app.digest.toString("hex"))).size
      !== prepared.length
    ) {
      throw new ApiError(
        400,
        "duplicate_application",
        "The registration contains the same application more than once"
      );
    }

    const context = await this.prisma.$transaction(async (transaction) => {
      const context = await this.lockAndRequireDevice(
        transaction,
        deviceCredential,
        ["pending_setup", "active"]
      );

      const existing = await transaction.managedApp.findMany({
        where: {
          childProfileId: context.childProfileId,
          sourceDeviceId: context.deviceId,
          archivedAt: null,
          OR: [
            { clientAppId: { in: prepared.map((app) => app.clientAppId) } },
            { tokenDigest: { in: prepared.map((app) => app.digest) } }
          ]
        }
      });
      const existingByClient = new Map(
        existing.map((app) => [app.clientAppId, app])
      );
      const existingByDigest = new Map(
        existing.map((app) => [Buffer.from(app.tokenDigest).toString("hex"), app])
      );
      const newApps: typeof prepared = [];
      for (const app of prepared) {
        const byClient = existingByClient.get(app.clientAppId);
        if (byClient !== undefined) {
          if (!timingSafeEqual(byClient.tokenDigest, app.digest)) {
            throw new ApiError(
              409,
              "client_app_id_conflict",
              "This local application ID is already bound to another token"
            );
          }
          continue;
        }
        if (existingByDigest.has(app.digest.toString("hex"))) {
          throw new ApiError(
            409,
            "duplicate_application",
            "This application is already registered with another local ID"
          );
        }
        newApps.push(app);
      }

      if (newApps.length > 0) {
        const registeredCount = await transaction.managedApp.count({
          where: {
            childProfileId: context.childProfileId,
            sourceDeviceId: context.deviceId,
            archivedAt: null
          }
        });
        if (registeredCount + newApps.length > 50) {
          throw new ApiError(
            422,
            "managed_app_limit_exceeded",
            "A child device can manage at most 50 applications"
          );
        }
        const currentVersion = await readCurrentVersion(
          transaction,
          context.childProfileId
        );
        const nextVersion = currentVersion + 1n;
        const fingerprint = stableFingerprint({
          childProfileId: context.childProfileId,
          deviceId: context.deviceId,
          apps: newApps.map((app) => ({
            clientAppId: app.clientAppId,
            tokenDigest: app.digest.toString("hex"),
            tokenFormatVersion: app.tokenFormatVersion
          })).sort((left, right) =>
            left.clientAppId.localeCompare(right.clientAppId)
          )
        });
        const policyVersion = await transaction.childPolicyVersion.create({
          data: {
            childProfileId: context.childProfileId,
            version: nextVersion,
            source: "initial_registration",
            idempotencyKey:
              `registration:${context.deviceId}:${nextVersion}:${fingerprint}`,
            requestFingerprint: fingerprint,
            createdAt: new Date(this.now())
          }
        });
        for (const app of newApps) {
          const managedApp = await transaction.managedApp.create({
            data: {
              childProfileId: context.childProfileId,
              sourceDeviceId: context.deviceId,
              clientAppId: app.clientAppId,
              tokenCiphertext: this.encrypt(app.tokenEnvelope),
              tokenDigest: app.digest,
              tokenFormatVersion: app.tokenFormatVersion,
              currentPolicy: "blocked",
              currentPolicyVersion: nextVersion,
              registeredAt: new Date(this.now())
            }
          });
          await transaction.appPolicyChange.create({
            data: {
              childProfileId: context.childProfileId,
              policyVersionId: policyVersion.id,
              managedAppId: managedApp.id,
              toPolicy: "blocked",
              createdAt: new Date(this.now())
            }
          });
        }
      }
      await this.touchDevice(transaction, context);
      return context;
    });
    return this.readAccess(context.childProfileId, context.deviceId);
  }

  async childAccess(
    deviceCredential: string | undefined
  ): Promise<AppAccessResponse> {
    const context = await this.prisma.$transaction(async (transaction) => {
      const context = await this.lockAndRequireDevice(
        transaction,
        deviceCredential,
        ["pending_setup", "active"]
      );
      await this.touchDevice(transaction, context);
      return context;
    });
    return this.readAccess(context.childProfileId, context.deviceId);
  }

  async createRequest(
    deviceCredential: string | undefined,
    input: AppRequestCreate
  ): Promise<AppAccessResponse> {
    const context = await this.prisma.$transaction(async (transaction) => {
      const context = await this.lockAndRequireDevice(
        transaction,
        deviceCredential,
        ["active"]
      );
      await transaction.$executeRaw`
        SELECT pg_advisory_xact_lock(
          hashtextextended(${"app-request:" + input.managedAppId}, 0)
        )
      `;
      const app = await transaction.managedApp.findFirst({
        where: {
          id: input.managedAppId,
          childProfileId: context.childProfileId,
          sourceDeviceId: context.deviceId,
          archivedAt: null
        }
      });
      if (app === null) {
        throw new ApiError(
          404,
          "managed_app_not_found",
          "The managed application does not exist"
        );
      }
      const fingerprint = stableFingerprint({
        childProfileId: context.childProfileId,
        managedAppId: input.managedAppId,
        message: input.message ?? null
      });
      const replay = await transaction.appRequest.findUnique({
        where: {
          childProfileId_requestIdempotencyKey: {
            childProfileId: context.childProfileId,
            requestIdempotencyKey: input.idempotencyKey
          }
        }
      });
      if (replay !== null) {
        if (
          replay.managedAppId !== input.managedAppId ||
          replay.requestFingerprint !== fingerprint
        ) {
          throw idempotencyConflict();
        }
        return context;
      }
      const pending = await transaction.appRequest.findFirst({
        where: { managedAppId: app.id, status: "pending" }
      });
      if (pending === null) {
        const created = await transaction.appRequest.create({
          data: {
            childProfileId: context.childProfileId,
            managedAppId: app.id,
            requestedByDeviceId: context.deviceId,
            message: input.message,
            requestIdempotencyKey: input.idempotencyKey,
            requestFingerprint: fingerprint,
            previousPolicy: app.currentPolicy,
            requestedAt: new Date(this.now())
          }
        });
        await transaction.pushOutboxEvent.create({
          data: {
            familyId: context.familyId,
            childProfileId: context.childProfileId,
            eventType: "app_request_created",
            payload: {
              requestId: created.id,
              childName: context.childName
            },
            nextAttemptAt: new Date(this.now()),
            createdAt: new Date(this.now()),
            updatedAt: new Date(this.now())
          }
        });
      }
      await this.touchDevice(transaction, context);
      return context;
    });
    return this.readAccess(context.childProfileId, context.deviceId);
  }

  async parentAccess(
    parent: ParentUser,
    childProfileId: string
  ): Promise<AppAccessResponse> {
    await this.requireParentChild(parent, childProfileId);
    const activeDevice = await this.prisma.device.findFirst({
      where: { childProfileId, status: "active" },
      orderBy: [{ pairedAt: "desc" }, { id: "desc" }],
      select: { id: true }
    });
    return this.readAccess(childProfileId, activeDevice?.id);
  }

  async decideRequest(
    parent: ParentUser,
    requestId: string,
    input: AppRequestDecision
  ): Promise<AppAccessResponse> {
    const childProfileId = await this.prisma.$transaction(async (transaction) => {
      const candidate = await transaction.appRequest.findUnique({
        where: { id: requestId },
        select: { childProfileId: true }
      });
      if (candidate === null) {
        throw new ApiError(404, "app_request_not_found", "The app request does not exist");
      }
      await lockPolicy(transaction, candidate.childProfileId);
      await requireParentChildInTransaction(
        transaction,
        parent,
        candidate.childProfileId
      );
      const request = await transaction.appRequest.findUniqueOrThrow({
        where: { id: requestId }
      });
      const decision = input.policy === "blocked" ? "denied" : "approved";
      const fingerprint = stableFingerprint({
        requestId,
        policy: input.policy,
        expectedPolicyVersion: input.expectedPolicyVersion,
        expectedRequestVersion: input.expectedRequestVersion
      });
      if (request.status === "decided") {
        if (
          request.decisionIdempotencyKey === input.idempotencyKey &&
          request.decisionFingerprint === fingerprint
        ) {
          return {
            childProfileId: request.childProfileId,
            deviceId: request.requestedByDeviceId
          };
        }
        throw new ApiError(
          409,
          "app_request_already_decided",
          "The app request has already been decided"
        );
      }
      const currentVersion = await readCurrentVersion(
        transaction,
        request.childProfileId
      );
      if (currentVersion !== BigInt(input.expectedPolicyVersion)) {
        throw policyVersionConflict();
      }
      if (request.requestVersion !== BigInt(input.expectedRequestVersion)) {
        throw new ApiError(
          409,
          "request_version_conflict",
          "The app request changed; refresh and try again"
        );
      }
      const app = await transaction.managedApp.findFirst({
        where: {
          id: request.managedAppId,
          childProfileId: request.childProfileId,
          archivedAt: null
        }
      });
      if (app === null) {
        throw new ApiError(
          404,
          "managed_app_not_found",
          "The managed application does not exist"
        );
      }
      const targetPolicy = decision === "denied"
        ? app.currentPolicy
        : input.policy;
      const nextVersion = currentVersion + 1n;
      const policyVersion = await transaction.childPolicyVersion.create({
        data: {
          childProfileId: request.childProfileId,
          version: nextVersion,
          source: "app_request_decision",
          actorUserId: parent.id,
          idempotencyKey: input.idempotencyKey,
          requestFingerprint: fingerprint,
          createdAt: new Date(this.now())
        }
      });
      await transaction.managedApp.update({
        where: { id: app.id },
        data: {
          currentPolicy: targetPolicy,
          currentPolicyVersion: nextVersion
        }
      });
      await transaction.appRequest.update({
        where: { id: request.id },
        data: {
          status: "decided",
          requestVersion: request.requestVersion + 1n,
          decision,
          decidedByUserId: parent.id,
          decisionIdempotencyKey: input.idempotencyKey,
          decisionFingerprint: fingerprint,
          decidedAt: new Date(this.now())
        }
      });
      await transaction.appPolicyChange.create({
        data: {
          childProfileId: request.childProfileId,
          policyVersionId: policyVersion.id,
          managedAppId: app.id,
          sourceRequestId: request.id,
          fromPolicy: app.currentPolicy,
          toPolicy: targetPolicy,
          changedByUserId: parent.id,
          createdAt: new Date(this.now())
        }
      });
      return {
        childProfileId: request.childProfileId,
        deviceId: app.sourceDeviceId
      };
    });
    return this.readAccess(childProfileId.childProfileId, childProfileId.deviceId);
  }

  async updatePolicy(
    parent: ParentUser,
    childProfileId: string,
    managedAppId: string,
    input: AppPolicyUpdate
  ): Promise<AppAccessResponse> {
    const sourceDeviceId = await this.prisma.$transaction(async (transaction) => {
      await lockPolicy(transaction, childProfileId);
      await requireParentChildInTransaction(transaction, parent, childProfileId);
      const fingerprint = stableFingerprint({
        childProfileId,
        managedAppId,
        policy: input.policy,
        expectedPolicyVersion: input.expectedPolicyVersion
      });
      const replay = await transaction.childPolicyVersion.findUnique({
        where: {
          childProfileId_idempotencyKey: {
            childProfileId,
            idempotencyKey: input.idempotencyKey
          }
        }
      });
      if (replay !== null) {
        if (replay.requestFingerprint !== fingerprint) {
          throw idempotencyConflict();
        }
        const replayApp = await transaction.managedApp.findFirst({
          where: { id: managedAppId, childProfileId, archivedAt: null },
          select: { sourceDeviceId: true }
        });
        if (replayApp === null) {
          throw new ApiError(
            404,
            "managed_app_not_found",
            "The managed application does not exist"
          );
        }
        return replayApp.sourceDeviceId;
      }
      const currentVersion = await readCurrentVersion(transaction, childProfileId);
      if (currentVersion !== BigInt(input.expectedPolicyVersion)) {
        throw policyVersionConflict();
      }
      const app = await transaction.managedApp.findFirst({
        where: { id: managedAppId, childProfileId, archivedAt: null }
      });
      if (app === null) {
        throw new ApiError(
          404,
          "managed_app_not_found",
          "The managed application does not exist"
        );
      }
      if (app.currentPolicy === input.policy) return app.sourceDeviceId;

      const nextVersion = currentVersion + 1n;
      const policyVersion = await transaction.childPolicyVersion.create({
        data: {
          childProfileId,
          version: nextVersion,
          source: "parent_change",
          actorUserId: parent.id,
          idempotencyKey: input.idempotencyKey,
          requestFingerprint: fingerprint,
          createdAt: new Date(this.now())
        }
      });
      await transaction.managedApp.update({
        where: { id: app.id },
        data: {
          currentPolicy: input.policy,
          currentPolicyVersion: nextVersion
        }
      });
      await transaction.appPolicyChange.create({
        data: {
          childProfileId,
          policyVersionId: policyVersion.id,
          managedAppId: app.id,
          fromPolicy: app.currentPolicy,
          toPolicy: input.policy,
          changedByUserId: parent.id,
          createdAt: new Date(this.now())
        }
      });
      return app.sourceDeviceId;
    });
    return this.readAccess(childProfileId, sourceDeviceId);
  }

  async acknowledge(
    deviceCredential: string | undefined,
    input: PolicyAck
  ): Promise<AppAccessResponse> {
    const context = await this.prisma.$transaction(async (transaction) => {
      const context = await this.lockAndRequireDevice(
        transaction,
        deviceCredential,
        ["pending_setup", "active"]
      );
      const version = await transaction.childPolicyVersion.findUnique({
        where: {
          childProfileId_version: {
            childProfileId: context.childProfileId,
            version: BigInt(input.policyVersion)
          }
        }
      });
      if (version === null) {
        throw new ApiError(
          409,
          "unknown_policy_version",
          "The policy version is not available for this child"
        );
      }
      const existing = await transaction.policyApplicationAck.findUnique({
        where: {
          deviceId_policyVersion: {
            deviceId: context.deviceId,
            policyVersion: BigInt(input.policyVersion)
          }
        }
      });
      if (
        existing !== null &&
        existing.result === "failed" &&
        input.result === "applied"
      ) {
        await transaction.policyApplicationAck.update({
          where: { id: existing.id },
          data: {
            result: "applied",
            failureReason: null,
            appliedAt: new Date(input.appliedAt),
            reportedAt: new Date(this.now())
          }
        });
      }
      if (existing === null) {
        await transaction.policyApplicationAck.create({
          data: {
            childProfileId: context.childProfileId,
            policyVersion: version.version,
            deviceId: context.deviceId,
            result: input.result,
            failureReason: input.failureReason,
            appliedAt: new Date(input.appliedAt),
            reportedAt: new Date(this.now())
          }
        });
        if (input.result === "failed") {
          await transaction.pushOutboxEvent.create({
            data: {
              familyId: context.familyId,
              childProfileId: context.childProfileId,
              eventType: "device_attention_required",
              payload: {
                childName: context.childName,
                policyVersion: input.policyVersion,
                failureReason: input.failureReason
              },
              nextAttemptAt: new Date(this.now()),
              createdAt: new Date(this.now()),
              updatedAt: new Date(this.now())
            }
          });
        }
      }
      await this.touchDevice(transaction, context);
      return context;
    });
    return this.readAccess(context.childProfileId, context.deviceId);
  }

  private async requireParentChild(
    parent: ParentUser,
    childProfileId: string
  ): Promise<void> {
    await requireParentChildInTransaction(this.prisma, parent, childProfileId);
  }

  private async requireDevice(
    client: Pick<Prisma, "deviceCredential">,
    deviceCredential: string | undefined,
    allowedStatuses: string[]
  ): Promise<DeviceContext> {
    if (deviceCredential === undefined) {
      throw unauthorized();
    }
    const now = new Date(this.now());
    const credential = await client.deviceCredential.findUnique({
      where: {
        tokenDigest: this.hash("child-credential", deviceCredential)
      },
      include: {
        device: {
          include: {
            childProfile: {
              select: {
                status: true,
                familyId: true,
                name: true
              }
            }
          }
        }
      }
    });
    if (credential === null) {
      throw unauthorized();
    }
    if (credential.device.childProfile.status === "archived") {
      throw childArchived();
    }
    if (
      credential.revokedAt !== null ||
      ["revoked", "replaced"].includes(credential.device.status)
    ) {
      throw deviceRevoked();
    }
    if (
      (credential.expiresAt !== null && now >= credential.expiresAt) ||
      !allowedStatuses.includes(credential.device.status) ||
      credential.device.childProfile.status !== "active"
    ) {
      throw unauthorized();
    }
    return {
      credentialId: credential.id,
      deviceId: credential.deviceId,
      childProfileId: credential.device.childProfileId,
      familyId: credential.device.childProfile.familyId,
      childName: credential.device.childProfile.name
    };
  }

  private async lockAndRequireDevice(
    transaction: Pick<Prisma, "$executeRaw" | "deviceCredential">,
    deviceCredential: string | undefined,
    allowedStatuses: string[]
  ): Promise<DeviceContext> {
    if (deviceCredential === undefined) {
      throw unauthorized();
    }
    const tokenDigest = this.hash("child-credential", deviceCredential);
    const candidate = await transaction.deviceCredential.findUnique({
      where: { tokenDigest },
      select: {
        device: { select: { childProfileId: true } }
      }
    });
    if (candidate === null) {
      throw unauthorized();
    }
    await lockPolicy(transaction, candidate.device.childProfileId);
    return this.requireDevice(
      transaction,
      deviceCredential,
      allowedStatuses
    );
  }

  private async touchDevice(
    client: Pick<Prisma, "device" | "deviceCredential">,
    context: DeviceContext
  ): Promise<void> {
    const now = new Date(this.now());
    await client.device.update({
      where: { id: context.deviceId },
      data: { lastSeenAt: now }
    });
    await client.deviceCredential.update({
      where: { id: context.credentialId },
      data: { lastUsedAt: now }
    });
  }

  private async readAccess(
    childProfileId: string,
    sourceDeviceId: string | undefined
  ): Promise<AppAccessResponse> {
    return this.prisma.$transaction(async (transaction) => {
      await lockPolicy(transaction, childProfileId);
      const policyVersion = await readCurrentVersion(
        transaction,
        childProfileId
      );
      if (sourceDeviceId === undefined) {
        return {
          policyVersion: safeNumber(policyVersion),
          apps: [],
          requests: []
        };
      }
      const [apps, requests] = await Promise.all([
        transaction.managedApp.findMany({
          where: { childProfileId, sourceDeviceId, archivedAt: null },
          orderBy: [{ registeredAt: "asc" }, { id: "asc" }]
        }),
        transaction.appRequest.findMany({
          where: { childProfileId, requestedByDeviceId: sourceDeviceId },
          orderBy: [{ requestedAt: "desc" }, { id: "desc" }],
          take: 100
        })
      ]);
      return {
        policyVersion: safeNumber(policyVersion),
        apps: apps.map((app) => ({
          id: app.id,
          clientAppId: app.clientAppId,
          tokenEnvelope: this.decrypt(app.tokenCiphertext),
          tokenFormatVersion: app.tokenFormatVersion,
          policy: app.currentPolicy as ManagedAppPolicy,
          policyVersion: safeNumber(app.currentPolicyVersion)
        })),
        requests: requests.map((request) => ({
          id: request.id,
          managedAppId: request.managedAppId,
          ...(request.message === null ? {} : { message: request.message }),
          status: request.status as "pending" | "decided",
          requestVersion: safeNumber(request.requestVersion),
          previousPolicy: request.previousPolicy as ManagedAppPolicy,
          ...(request.decision === null
            ? {}
            : { decision: request.decision as "approved" | "denied" }),
          requestedAt: request.requestedAt.toISOString(),
          ...(request.decidedAt === null
            ? {}
            : { decidedAt: request.decidedAt.toISOString() })
        }))
      };
    });
  }

  private hash(label: string, value: string): Buffer {
    return createHmac("sha256", this.pepper)
      .update(label)
      .update("\0")
      .update(value)
      .digest();
  }

  private encrypt(value: string): Buffer {
    const iv = randomBytes(envelopeIVBytes);
    const cipher = createCipheriv("aes-256-gcm", this.encryptionKey, iv);
    const ciphertext = Buffer.concat([
      cipher.update(value, "utf8"),
      cipher.final()
    ]);
    return Buffer.concat([
      Buffer.from(Uint8Array.of(envelopeCipherVersion)),
      iv,
      cipher.getAuthTag(),
      ciphertext
    ]);
  }

  private decrypt(envelope: Uint8Array): string {
    const data = Buffer.from(envelope);
    const minimumLength = 1 + envelopeIVBytes + envelopeTagBytes + 1;
    if (data.length < minimumLength || data[0] !== envelopeCipherVersion) {
      throw new Error("Stored managed app token envelope is invalid");
    }
    const ivStart = 1;
    const tagStart = ivStart + envelopeIVBytes;
    const ciphertextStart = tagStart + envelopeTagBytes;
    const decipher = createDecipheriv(
      "aes-256-gcm",
      this.encryptionKey,
      data.subarray(ivStart, tagStart)
    );
    decipher.setAuthTag(data.subarray(tagStart, ciphertextStart));
    return Buffer.concat([
      decipher.update(data.subarray(ciphertextStart)),
      decipher.final()
    ]).toString("utf8");
  }
}

interface DeviceContext {
  credentialId: string;
  deviceId: string;
  childProfileId: string;
  familyId: string;
  childName: string;
}

async function lockPolicy(
  client: Pick<Prisma, "$executeRaw">,
  childProfileId: string
): Promise<void> {
  await client.$executeRaw`
    SELECT pg_advisory_xact_lock(
      hashtextextended(${"app-policy:" + childProfileId}, 0)
    )
  `;
}

async function readCurrentVersion(
  client: Pick<Prisma, "childPolicyVersion">,
  childProfileId: string
): Promise<bigint> {
  const latest = await client.childPolicyVersion.findFirst({
    where: { childProfileId },
    orderBy: { version: "desc" },
    select: { version: true }
  });
  return latest?.version ?? 0n;
}

async function requireParentChildInTransaction(
  client: Pick<Prisma, "childProfile">,
  parent: ParentUser,
  childProfileId: string
): Promise<void> {
  const child = await client.childProfile.findFirst({
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
    select: { id: true }
  });
  if (child === null) {
    throw new ApiError(404, "child_not_found", "The child profile does not exist");
  }
}

function validateTokenEnvelope(value: string): void {
  if (
    value.length % 4 !== 0 ||
    !/^[A-Za-z0-9+/]+={0,2}$/.test(value)
  ) {
    throw invalidTokenEnvelope();
  }
  const decoded = Buffer.from(value, "base64");
  if (
    decoded.length === 0 ||
    decoded.length > maximumDecodedEnvelopeBytes ||
    decoded.toString("base64") !== value
  ) {
    throw invalidTokenEnvelope();
  }
}

function invalidTokenEnvelope(): ApiError {
  return new ApiError(
    400,
    "invalid_token_envelope",
    "The managed application token envelope is invalid"
  );
}

function unauthorized(): ApiError {
  return new ApiError(
    401,
    "unauthorized",
    "The child device bearer token is invalid or revoked"
  );
}

function deviceRevoked(): ApiError {
  return new ApiError(
    401,
    "device_revoked",
    "A parent disconnected this device from PagePass"
  );
}

function childArchived(): ApiError {
  return new ApiError(
    401,
    "child_archived",
    "The child profile was archived"
  );
}

function idempotencyConflict(): ApiError {
  return new ApiError(
    409,
    "idempotency_conflict",
    "The idempotency key was already used for another operation"
  );
}

function policyVersionConflict(): ApiError {
  return new ApiError(
    409,
    "policy_version_conflict",
    "The app policy changed; refresh and try again"
  );
}

function safeNumber(value: bigint): number {
  if (value < 0n || value > BigInt(Number.MAX_SAFE_INTEGER)) {
    throw new Error("Stored policy version is outside the supported range");
  }
  return Number(value);
}
