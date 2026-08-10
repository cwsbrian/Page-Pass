import { createHmac } from "node:crypto";

import type {
  CreditGrant,
  CreditGrantResponse,
  EarnedTimeStart,
  EarnedTimeStartResponse,
  EarnedTimeSettlement,
  EarnedTimeSettlementResponse
} from "../../../../libs/shared/src/index.js";
import {
  ApiError,
  stableFingerprint,
  type StoreResult
} from "../domain.js";
import type { Prisma, PrismaTransaction } from "../db/prisma.js";
import type { ParentUser } from "../family/family-service.js";

const maximumSafeBalance = BigInt(Number.MAX_SAFE_INTEGER);

export interface LegacyCreditStore {
  settleEarnedTime(
    token: string | undefined,
    localSessionId: string,
    input: EarnedTimeSettlement
  ): StoreResult<EarnedTimeSettlementResponse>;
}

export interface CreditServiceOptions {
  pepper: string | Buffer;
  now?: () => number;
  legacy?: LegacyCreditStore;
}

export interface CreditApi {
  grant(
    parent: ParentUser,
    childProfileId: string,
    input: CreditGrant
  ): Promise<CreditGrantResponse>;
  start(
    deviceCredential: string | undefined,
    localSessionId: string,
    input: EarnedTimeStart
  ): Promise<EarnedTimeStartResponse>;
  activate(
    deviceCredential: string | undefined,
    localSessionId: string
  ): Promise<EarnedTimeStartResponse>;
  settle(
    deviceCredential: string | undefined,
    localSessionId: string,
    input: EarnedTimeSettlement
  ): Promise<EarnedTimeSettlementResponse>;
}

export class PrismaCreditService implements CreditApi {
  private readonly pepper: Buffer;
  private readonly now: () => number;

  constructor(
    private readonly prisma: Prisma,
    private readonly options: CreditServiceOptions
  ) {
    this.pepper = Buffer.isBuffer(options.pepper)
      ? Buffer.from(options.pepper)
      : Buffer.from(options.pepper, "utf8");
    this.now = options.now ?? Date.now;
  }

  async grant(
    parent: ParentUser,
    childProfileId: string,
    input: CreditGrant
  ): Promise<CreditGrantResponse> {
    const fingerprint = stableFingerprint({ childProfileId, ...input });
    return this.prisma.$transaction(async (transaction) => {
      await lockChildCredit(transaction, childProfileId);
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
        select: { id: true }
      });
      if (child === null) {
        throw new ApiError(404, "child_not_found", "The child profile does not exist");
      }

      const existingSettlement = await transaction.earnedTimeSession.findUnique({
        where: {
          childProfileId_settlementIdempotencyKey: {
            childProfileId,
            settlementIdempotencyKey: input.idempotencyKey
          }
        },
        select: { id: true }
      });
      if (existingSettlement !== null) throw idempotencyConflict();

      const existing = await transaction.creditLedgerEntry.findUnique({
        where: {
          childProfileId_idempotencyKey: {
            childProfileId,
            idempotencyKey: input.idempotencyKey
          }
        }
      });
      if (existing !== null) {
        if (
          existing.entryType !== "parent_grant" ||
          existing.requestFingerprint !== fingerprint
        ) {
          throw idempotencyConflict();
        }
        if (existing.reason === null || existing.amountSeconds <= 0n) {
          throw new Error("Stored parent grant is malformed");
        }
        return {
          id: existing.id,
          childProfileId,
          seconds: safeNumber(existing.amountSeconds),
          reason: existing.reason,
          idempotencyKey: existing.idempotencyKey,
          createdAt: existing.createdAt.toISOString(),
          balanceSeconds: safeNumber(existing.balanceAfterSeconds),
          ledgerRevision: safeNumber(existing.ledgerRevision)
        };
      }

      const balance = await requireBalance(transaction, childProfileId);
      const nextBalance = balance.balanceSeconds + BigInt(input.seconds);
      if (nextBalance > maximumSafeBalance) {
        throw new ApiError(
          422,
          "balance_limit_exceeded",
          "The credit grant would exceed the supported balance"
        );
      }
      const nextRevision = balance.ledgerRevision + 1n;
      const createdAt = new Date(this.now());
      const entry = await transaction.creditLedgerEntry.create({
        data: {
          childProfileId,
          ledgerRevision: nextRevision,
          entryType: "parent_grant",
          amountSeconds: BigInt(input.seconds),
          balanceAfterSeconds: nextBalance,
          actorUserId: parent.id,
          reason: input.reason,
          idempotencyKey: input.idempotencyKey,
          requestFingerprint: fingerprint,
          createdAt
        }
      });
      await transaction.childCreditBalance.update({
        where: { childProfileId },
        data: {
          balanceSeconds: nextBalance,
          ledgerRevision: nextRevision,
          updatedAt: createdAt
        }
      });

      return {
        id: entry.id,
        childProfileId,
        seconds: input.seconds,
        reason: input.reason,
        idempotencyKey: input.idempotencyKey,
        createdAt: createdAt.toISOString(),
        balanceSeconds: safeNumber(nextBalance),
        ledgerRevision: safeNumber(nextRevision)
      };
    });
  }

  async start(
    deviceCredential: string | undefined,
    localSessionId: string,
    input: EarnedTimeStart
  ): Promise<EarnedTimeStartResponse> {
    if (deviceCredential === undefined) {
      throw unauthorized("A child device bearer token is required");
    }
    const digest = this.hash("child-credential", deviceCredential);
    const fingerprint = stableFingerprint(input);

    const result = await this.prisma.$transaction(async (transaction) => {
      const credential = await lockTargetCredentialWithPolicyAndCredit(
        transaction,
        digest
      );
      if (credential === null) return undefined;
      const now = new Date(this.now());
      validateActiveCredential(credential, now);

      const childProfileId = credential.device.childProfile.id;
      await requireAppliedEarnedTimePolicy(transaction, credential);
      const existing = await transaction.earnedTimeSession.findUnique({
        where: {
          childProfileId_localSessionId: {
            childProfileId,
            localSessionId
          }
        }
      });
      if (existing !== null) {
        if (
          existing.state !== "prepared" ||
          existing.requestFingerprint !== fingerprint
        ) {
          throw new ApiError(
            409,
            "session_identity_conflict",
            "This local session ID is already bound to different session data"
          );
        }
        return startResponse(existing);
      }

      const unsettled = await transaction.earnedTimeSession.findFirst({
        where: {
          childProfileId,
          state: { in: ["prepared", "active", "settlement_pending"] }
        },
        select: { id: true }
      });
      let recoveredExpiredSession = false;
      if (unsettled !== null) {
        const stale = await transaction.earnedTimeSession.findUniqueOrThrow({
          where: { id: unsettled.id }
        });
        if (stale.state === "prepared") {
          await transaction.earnedTimeSession.update({
            where: { id: stale.id },
            data: {
              state: "cancelled",
              endedAt: now,
              consumedSeconds: 0,
              balanceAfterSeconds: stale.balanceBeforeSeconds,
              endReason: "recovery",
              settledAt: now,
              updatedAt: now
            }
          });
        } else if (stale.state === "active" && now >= stale.expiresAt) {
          await settleExpiredSession(transaction, stale, now);
          recoveredExpiredSession = true;
        } else {
          throw new ApiError(
            409,
            "active_session_exists",
            "This child already has an unsettled earned-time session"
          );
        }
      }

      const balance = await requireBalance(transaction, childProfileId);
      if (BigInt(input.requestedDurationSeconds) > balance.balanceSeconds) {
        if (recoveredExpiredSession) {
          return { recoveredInsufficientBalance: true as const };
        }
        throw new ApiError(
          422,
          "insufficient_balance",
          "The child does not have enough canonical balance to start this session"
        );
      }
      const expiresAt = new Date(
        now.getTime() + input.requestedDurationSeconds * 1_000
      );
      const session = await transaction.earnedTimeSession.create({
        data: {
          childProfileId,
          deviceId: credential.deviceId,
          localSessionId,
          requestedDurationSeconds: input.requestedDurationSeconds,
          balanceBeforeSeconds: balance.balanceSeconds,
          startedAt: now,
          expiresAt,
          state: "prepared",
          requestFingerprint: fingerprint,
          preparedAt: now,
          createdAt: now,
          updatedAt: now
        }
      });
      await touchCredential(transaction, credential, now);
      return startResponse(session);
    });
    if (result === undefined) {
      throw unauthorized("The child device bearer token is invalid or revoked");
    }
    if ("recoveredInsufficientBalance" in result) {
      throw new ApiError(
        422,
        "insufficient_balance",
        "The child does not have enough canonical balance to start this session"
      );
    }
    return result;
  }

  async activate(
    deviceCredential: string | undefined,
    localSessionId: string
  ): Promise<EarnedTimeStartResponse> {
    if (deviceCredential === undefined) {
      throw unauthorized("A child device bearer token is required");
    }
    const digest = this.hash("child-credential", deviceCredential);
    const result = await this.prisma.$transaction(async (transaction) => {
      const credential = await lockTargetCredentialWithPolicyAndCredit(
        transaction,
        digest
      );
      if (credential === null) return undefined;
      const now = new Date(this.now());
      validateActiveCredential(credential, now);

      const childProfileId = credential.device.childProfile.id;
      await requireAppliedEarnedTimePolicy(transaction, credential);
      const session = await transaction.earnedTimeSession.findUnique({
        where: {
          childProfileId_localSessionId: {
            childProfileId,
            localSessionId
          }
        }
      });
      if (session === null || session.deviceId !== credential.deviceId) {
        throw new ApiError(
          409,
          "session_not_prepared",
          "This earned-time session is not prepared on this device"
        );
      }
      if (session.state === "active") return startResponse(session);
      if (session.state !== "prepared") {
        throw new ApiError(
          409,
          "session_not_prepared",
          "This earned-time session can no longer be activated"
        );
      }
      if (now >= session.expiresAt) {
        throw new ApiError(
          410,
          "session_preparation_expired",
          "This earned-time preparation has expired"
        );
      }
      const active = await transaction.earnedTimeSession.update({
        where: { id: session.id },
        data: {
          state: "active",
          startedAt: now,
          expiresAt: new Date(
            now.getTime() + session.requestedDurationSeconds * 1_000
          ),
          activeSyncedAt: now,
          updatedAt: now
        }
      });
      await touchCredential(transaction, credential, now);
      return startResponse(active);
    });
    if (result !== undefined) return result;
    throw unauthorized("The child device bearer token is invalid or revoked");
  }

  async settle(
    deviceCredential: string | undefined,
    localSessionId: string,
    input: EarnedTimeSettlement
  ): Promise<EarnedTimeSettlementResponse> {
    if (deviceCredential === undefined) {
      throw unauthorized("A child device bearer token is required");
    }
    if (input.localSessionId !== localSessionId) {
      throw new ApiError(
        409,
        "local_session_id_mismatch",
        "The path and body localSessionId values must match"
      );
    }

    const target = await this.settleTarget(
      deviceCredential,
      localSessionId,
      input
    );
    if (target !== undefined) return target;
    if (this.options.legacy !== undefined) {
      return this.options.legacy.settleEarnedTime(
        deviceCredential,
        localSessionId,
        input
      );
    }
    throw unauthorized("The child device bearer token is invalid or revoked");
  }

  private async settleTarget(
    deviceCredential: string,
    localSessionId: string,
    input: EarnedTimeSettlement
  ): Promise<EarnedTimeSettlementResponse | undefined> {
    const digest = this.hash("child-credential", deviceCredential);
    const fingerprint = stableFingerprint(input);
    return this.prisma.$transaction(async (transaction) => {
      const candidate = await transaction.deviceCredential.findUnique({
        where: { tokenDigest: digest },
        select: {
          device: { select: { childProfileId: true } }
        }
      });
      if (candidate === null) return undefined;
      await lockChildCredit(transaction, candidate.device.childProfileId);
      const credential = await lockTargetCredential(transaction, digest);
      if (credential === null) return undefined;
      const now = new Date(this.now());
      validateActiveCredential(credential, now);

      const childProfileId = credential.device.childProfile.id;

      const existingByKey = await transaction.earnedTimeSession.findUnique({
        where: {
          childProfileId_settlementIdempotencyKey: {
            childProfileId,
            settlementIdempotencyKey: input.idempotencyKey
          }
        }
      });
      if (existingByKey !== null) {
        if (
          existingByKey.localSessionId !== localSessionId ||
          existingByKey.requestFingerprint !== fingerprint
        ) {
          throw idempotencyConflict();
        }
        return settledResponse(existingByKey);
      }

      const conflictingLedger = await transaction.creditLedgerEntry.findUnique({
        where: {
          childProfileId_idempotencyKey: {
            childProfileId,
            idempotencyKey: input.idempotencyKey
          }
        },
        select: { id: true }
      });
      if (conflictingLedger !== null) throw idempotencyConflict();

      const session = await transaction.earnedTimeSession.findUnique({
        where: {
          childProfileId_localSessionId: {
            childProfileId,
            localSessionId
          }
        }
      });
      if (session === null) {
        throw new ApiError(
          409,
          "session_not_started",
          "This earned-time session was not started by the server"
        );
      }
      if (session.deviceId !== credential.deviceId) {
        throw unauthorized("This earned-time session belongs to another device");
      }
      if (
        session.state === "settled" &&
        session.settlementIdempotencyKey?.startsWith("server-expiry:")
      ) {
        validateSettlementIdentity(session, input);
        const adopted = await transaction.earnedTimeSession.update({
          where: { id: session.id },
          data: {
            settlementIdempotencyKey: input.idempotencyKey,
            requestFingerprint: fingerprint,
            updatedAt: now
          }
        });
        await touchCredential(transaction, credential, now);
        return settledResponse(adopted);
      }
      if (session.state === "prepared") {
        const cancelled = await transaction.earnedTimeSession.update({
          where: { id: session.id },
          data: {
            state: "cancelled",
            endedAt: now,
            consumedSeconds: 0,
            balanceAfterSeconds: session.balanceBeforeSeconds,
            endReason: input.endReason === "activation_failed"
              ? "activation_failed"
              : "manual_stop",
            settlementIdempotencyKey: input.idempotencyKey,
            requestFingerprint: fingerprint,
            settledAt: now,
            updatedAt: now
          }
        });
        await touchCredential(transaction, credential, now);
        return settledResponse(cancelled);
      }
      if (session.state !== "active") {
        throw new ApiError(
          409,
          "session_already_settled",
          "This earned-time session is not active"
        );
      }
      if (input.endReason === "activation_failed") {
        validateSettlementEnvelope(session, input);
      } else {
        validateSettlementIdentity(session, input);
      }
      if (
        !["manual_stop", "activation_failed"].includes(input.endReason) &&
        now < session.expiresAt
      ) {
        throw new ApiError(
          422,
          "session_not_expired",
          "Expired and recovery settlement cannot occur before server expiry"
        );
      }
      const billingStartedAt = session.activeSyncedAt ?? session.startedAt;
      const reportedEndedAt = new Date(input.endedAt);
      if (
        input.endReason === "manual_stop" &&
        reportedEndedAt.getTime() > now.getTime() + 30_000
      ) {
        throw new ApiError(
          422,
          "settlement_ended_at_in_future",
          "The settlement endedAt is too far ahead of server time"
        );
      }
      const effectiveEndedAt = input.endReason === "manual_stop"
        ? reportedEndedAt
        : now;
      const billingEndedAt = new Date(Math.min(
        effectiveEndedAt.getTime(),
        now.getTime(),
        session.expiresAt.getTime()
      ));
      const consumedSeconds = (
        input.endReason === "manual_stop" ||
        input.endReason === "activation_failed"
      )
        ? Math.min(
            session.requestedDurationSeconds,
            Math.max(
              0,
              Math.ceil(
                (
                  billingEndedAt.getTime() - billingStartedAt.getTime()
                ) / 1_000
              )
            )
          )
        : session.requestedDurationSeconds;
      const balance = await requireBalance(transaction, childProfileId);
      if (BigInt(consumedSeconds) > balance.balanceSeconds) {
        throw new ApiError(
          422,
          "insufficient_balance",
          "The child does not have enough canonical balance for this settlement"
        );
      }

      const nextBalance = balance.balanceSeconds - BigInt(consumedSeconds);
      const nextRevision = consumedSeconds === 0
        ? balance.ledgerRevision
        : balance.ledgerRevision + 1n;
      const settledSession = await transaction.earnedTimeSession.update({
        where: { id: session.id },
        data: {
          balanceAfterSeconds: nextBalance,
          state: "settled",
          endedAt: billingEndedAt,
          consumedSeconds,
          endReason: input.endReason,
          settlementIdempotencyKey: input.idempotencyKey,
          requestFingerprint: fingerprint,
          settledAt: now,
          updatedAt: now
        }
      });

      if (consumedSeconds > 0) {
        await transaction.creditLedgerEntry.create({
          data: {
            childProfileId,
            ledgerRevision: nextRevision,
            entryType: "session_spend",
            amountSeconds: -consumedSeconds,
            balanceAfterSeconds: nextBalance,
            earnedTimeSessionId: settledSession.id,
            reason: input.endReason,
            idempotencyKey: input.idempotencyKey,
            requestFingerprint: fingerprint,
            createdAt: now
          }
        });
        await transaction.childCreditBalance.update({
          where: { childProfileId },
          data: {
            balanceSeconds: nextBalance,
            ledgerRevision: nextRevision,
            updatedAt: now
          }
        });
      }
      await touchCredential(transaction, credential, now);

      await transaction.pushOutboxEvent.create({
        data: {
          familyId: credential.device.childProfile.familyId,
          childProfileId,
          eventType: "earned_time_session_ended",
          payload: {
            childName: credential.device.childProfile.name,
            sessionId: settledSession.id,
            consumedSeconds,
            endReason: input.endReason,
            balanceSeconds: safeNumber(nextBalance)
          },
          nextAttemptAt: now,
          createdAt: now,
          updatedAt: now
        }
      });

      return {
        id: settledSession.id,
        localSessionId,
        consumedSeconds,
        balanceSeconds: safeNumber(nextBalance),
        settledAt: now.toISOString()
      };
    });
  }

  private hash(scope: string, value: string): Buffer {
    return createHmac("sha256", this.pepper)
      .update(`${scope}\0${value}`)
      .digest();
  }
}

async function lockChildCredit(
  transaction: Pick<Prisma, "$executeRaw">,
  childProfileId: string
): Promise<void> {
  await transaction.$executeRaw`
    SELECT pg_advisory_xact_lock(
      hashtextextended(${"credit-child:" + childProfileId}, 0)
    )
  `;
}

async function lockTargetCredential(
  transaction: Pick<Prisma, "$queryRaw" | "deviceCredential">,
  digest: Buffer
) {
  const candidate = await transaction.deviceCredential.findUnique({
    where: { tokenDigest: digest },
    select: { id: true, deviceId: true }
  });
  if (candidate === null) return null;

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
  return transaction.deviceCredential.findUnique({
    where: { id: candidate.id },
    include: {
      device: {
        include: {
          childProfile: {
            select: {
              id: true,
              status: true,
              familyId: true,
              name: true
            }
          }
        }
      }
    }
  });
}

async function lockTargetCredentialWithPolicyAndCredit(
  transaction: PrismaTransaction,
  tokenDigest: Buffer
) {
  const candidate = await transaction.deviceCredential.findUnique({
    where: { tokenDigest },
    select: {
      device: {
        select: { childProfileId: true }
      }
    }
  });
  if (candidate === null) return null;
  await transaction.$executeRaw`
    SELECT pg_advisory_xact_lock(
      hashtextextended(
        ${"app-policy:" + candidate.device.childProfileId},
        0
      )
    )
  `;
  await lockChildCredit(transaction, candidate.device.childProfileId);
  return lockTargetCredential(transaction, tokenDigest);
}

async function requireAppliedEarnedTimePolicy(
  transaction: Pick<
    Prisma,
    "childPolicyVersion" | "managedApp" | "policyApplicationAck"
  >,
  credential: {
    deviceId: string;
    device: {
      childProfile: { id: string };
    };
  }
): Promise<void> {
  const latestPolicy = await transaction.childPolicyVersion.findFirst({
    where: { childProfileId: credential.device.childProfile.id },
    orderBy: { version: "desc" },
    select: { version: true }
  });
  const ack = latestPolicy === null
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
  const earnedTimeApps = await transaction.managedApp.count({
    where: {
      childProfileId: credential.device.childProfile.id,
      sourceDeviceId: credential.deviceId,
      currentPolicy: "earned_time",
      archivedAt: null
    }
  });
  if (latestPolicy === null || ack?.result !== "applied") {
    throw new ApiError(
      409,
      "policy_sync_required",
      "The latest app policy must be applied before Earned Time can start"
    );
  }
  if (earnedTimeApps === 0) {
    throw new ApiError(
      409,
      "earned_time_policy_empty",
      "No applications are currently approved for Earned Time"
    );
  }
}

function validateActiveCredential(
  credential: {
    revokedAt: Date | null;
    expiresAt: Date | null;
    device: {
      status: string;
      childProfile: { status: string };
    };
  },
  now: Date
): void {
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
  if (
    (credential.expiresAt !== null && now >= credential.expiresAt) ||
    credential.device.status !== "active" ||
    credential.device.childProfile.status !== "active"
  ) {
    throw unauthorized("The child device bearer token is invalid or not active");
  }
}

async function touchCredential(
  transaction: Pick<Prisma, "device" | "deviceCredential">,
  credential: { id: string; deviceId: string },
  now: Date
): Promise<void> {
  await transaction.device.update({
    where: { id: credential.deviceId },
    data: { lastSeenAt: now }
  });
  await transaction.deviceCredential.update({
    where: { id: credential.id },
    data: { lastUsedAt: now }
  });
}

async function requireBalance(
  transaction: Pick<Prisma, "childCreditBalance">,
  childProfileId: string
) {
  const balance = await transaction.childCreditBalance.findUnique({
    where: { childProfileId }
  });
  if (balance === null) {
    throw new Error(`Credit balance is missing for child ${childProfileId}`);
  }
  return balance;
}

export async function settleExpiredSession(
  transaction: Pick<
    Prisma,
    "childCreditBalance" | "creditLedgerEntry" | "earnedTimeSession"
  >,
  session: {
    id: string;
    childProfileId: string;
    localSessionId: string;
    requestedDurationSeconds: number;
    expiresAt: Date;
  },
  now: Date
): Promise<void> {
  const balance = await requireBalance(transaction, session.childProfileId);
  const consumedSeconds = BigInt(session.requestedDurationSeconds);
  if (consumedSeconds > balance.balanceSeconds) {
    throw new Error(
      `Expired session ${session.id} exceeds its child's canonical balance`
    );
  }

  const nextBalance = balance.balanceSeconds - consumedSeconds;
  const nextRevision = balance.ledgerRevision + 1n;
  const idempotencyKey = `server-expiry:${session.id}`;
  const requestFingerprint = stableFingerprint({
    localSessionId: session.localSessionId,
    endReason: "recovery",
    expiresAt: session.expiresAt.toISOString()
  });
  await transaction.earnedTimeSession.update({
    where: { id: session.id },
    data: {
      balanceAfterSeconds: nextBalance,
      state: "settled",
      endedAt: session.expiresAt,
      consumedSeconds: session.requestedDurationSeconds,
      endReason: "recovery",
      settlementIdempotencyKey: idempotencyKey,
      settledAt: now,
      updatedAt: now
    }
  });
  await transaction.creditLedgerEntry.create({
    data: {
      childProfileId: session.childProfileId,
      ledgerRevision: nextRevision,
      entryType: "session_spend",
      amountSeconds: -consumedSeconds,
      balanceAfterSeconds: nextBalance,
      earnedTimeSessionId: session.id,
      reason: "recovery",
      idempotencyKey,
      requestFingerprint,
      createdAt: now
    }
  });
  await transaction.childCreditBalance.update({
    where: { childProfileId: session.childProfileId },
    data: {
      balanceSeconds: nextBalance,
      ledgerRevision: nextRevision,
      updatedAt: now
    }
  });
}

function validateSettlementIdentity(
  session: {
    requestedDurationSeconds: number;
    balanceBeforeSeconds: bigint;
    startedAt: Date;
    expiresAt: Date;
  },
  input: EarnedTimeSettlement
): void {
  validateSettlementEnvelope(session, input);
  if (
    session.startedAt.getTime() !== Date.parse(input.startedAt) ||
    session.expiresAt.getTime() !== Date.parse(input.expiresAt)
  ) {
    throw new ApiError(
      409,
      "session_identity_conflict",
      "Settlement data does not match the server-started session"
    );
  }
}

function validateSettlementEnvelope(
  session: {
    requestedDurationSeconds: number;
    balanceBeforeSeconds: bigint;
  },
  input: EarnedTimeSettlement
): void {
  if (
    session.requestedDurationSeconds !== input.requestedDurationSeconds ||
    session.balanceBeforeSeconds !== BigInt(input.balanceBeforeSeconds)
  ) {
    throw new ApiError(
      409,
      "session_identity_conflict",
      "Settlement data does not match the server-started session"
    );
  }
}

function startResponse(session: {
  localSessionId: string;
  requestedDurationSeconds: number;
  balanceBeforeSeconds: bigint;
  startedAt: Date;
  expiresAt: Date;
}): EarnedTimeStartResponse {
  return {
    localSessionId: session.localSessionId,
    requestedDurationSeconds: session.requestedDurationSeconds,
    balanceBeforeSeconds: safeNumber(session.balanceBeforeSeconds),
    startedAt: session.startedAt.toISOString(),
    expiresAt: session.expiresAt.toISOString()
  };
}

function settledResponse(session: {
  id: string;
  localSessionId: string;
  consumedSeconds: number | null;
  balanceAfterSeconds: bigint | null;
  settledAt: Date | null;
}): EarnedTimeSettlementResponse {
  if (
    session.consumedSeconds === null ||
    session.balanceAfterSeconds === null ||
    session.settledAt === null
  ) {
    throw new Error("Stored earned-time settlement is incomplete");
  }
  return {
    id: session.id,
    localSessionId: session.localSessionId,
    consumedSeconds: session.consumedSeconds,
    balanceSeconds: safeNumber(session.balanceAfterSeconds),
    settledAt: session.settledAt.toISOString()
  };
}

function safeNumber(value: bigint): number {
  if (value < 0n || value > maximumSafeBalance) {
    throw new Error("Stored credit value is outside the supported range");
  }
  return Number(value);
}

function unauthorized(message: string): ApiError {
  return new ApiError(401, "unauthorized", message);
}

function idempotencyConflict(): ApiError {
  return new ApiError(
    409,
    "idempotency_conflict",
    "The idempotency key was already used with a different request"
  );
}
