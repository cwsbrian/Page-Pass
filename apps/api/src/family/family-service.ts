import {
  createHmac,
  randomUUID,
  timingSafeEqual
} from "node:crypto";

import type {
  ArchivedChild,
  Child,
  ClaimLocalDataRequest,
  ClaimLocalDataResponse,
  CreditLedgerResponse,
  FamilyPreferences,
  Parent,
  ParentHomeResponse,
  ParentPreferences,
  UpdateParentPreferences,
  UpdateFamilyPreferences
} from "../../../../libs/shared/src/index.js";

import { ApiError } from "../domain.js";
import type { Prisma, PrismaTransaction } from "../db/prisma.js";

export interface ParentUser {
  id: string;
  name: string;
  sessionCreatedAt?: Date;
}

interface FamilyScope {
  id: string;
}

interface LegacyClaimState {
  parent_token_hash: Uint8Array;
  local_data_claimed_parent_id: string | null;
  local_data_migrated_family_id: string | null;
  local_data_migrated_children: number | null;
}

interface LegacyLedgerEvent {
  source: "grant" | "spend";
  sourceId: string;
  amountSeconds: bigint;
  balanceAfterSeconds: bigint;
  idempotencyKey: string;
  requestFingerprint: string;
  reason: string;
  createdAt: Date;
}

const legacyLocalParentId = "00000000-0000-4000-8000-000000000001";
const maximumSafeInteger = BigInt(Number.MAX_SAFE_INTEGER);
const deviceStatusStaleAfterMs = 24 * 60 * 60 * 1_000;

export class PrismaFamilyService {
  constructor(
    private readonly prisma: Prisma,
    private readonly options: {
      now?: () => number;
      legacyMigrationPepper?: string | Buffer;
    } = {}
  ) {}

  async ensureParentUser(
    user: ParentUser,
    email: string
  ): Promise<void> {
    await this.prisma.user.upsert({
      where: { id: user.id },
      update: {
        name: user.name,
        status: "active"
      },
      create: {
        id: user.id,
        name: user.name,
        email,
        emailVerified: true,
        status: "active"
      }
    });
  }

  async parent(user: ParentUser): Promise<Parent> {
    await this.ensureFamily(user);
    return {
      id: user.id,
      displayName: user.name
    };
  }

  async listChildren(user: ParentUser): Promise<Child[]> {
    const family = await this.ensureFamily(user);
    const children = await this.prisma.childProfile.findMany({
      where: {
        familyId: family.id,
        status: "active"
      },
      orderBy: [{ createdAt: "asc" }, { id: "asc" }],
      include: {
        creditBalance: true,
        devices: {
          where: { status: "active" },
          orderBy: { pairedAt: "desc" },
          select: { deviceName: true },
          take: 1
        }
      }
    });

    return children.map((child) => ({
      id: child.id,
      name: child.name,
      balanceSeconds: balanceSeconds(child.creditBalance),
      ...(child.devices[0] === undefined
        ? {}
        : { activeDeviceName: child.devices[0].deviceName })
    }));
  }

  async listArchivedChildren(user: ParentUser): Promise<ArchivedChild[]> {
    const family = await this.ensureFamily(user);
    const children = await this.prisma.childProfile.findMany({
      where: {
        familyId: family.id,
        status: "archived",
        archivedAt: { not: null }
      },
      orderBy: [{ archivedAt: "desc" }, { id: "asc" }],
      include: { creditBalance: true }
    });

    return children.map((child) => ({
      id: child.id,
      name: child.name,
      balanceSeconds: balanceSeconds(child.creditBalance),
      archivedAt: child.archivedAt!.toISOString()
    }));
  }

  async home(user: ParentUser): Promise<ParentHomeResponse> {
    const family = await this.ensureFamily(user);
    const children = await this.prisma.childProfile.findMany({
      where: {
        familyId: family.id,
        status: "active"
      },
      orderBy: [{ createdAt: "asc" }, { id: "asc" }],
      include: {
        creditBalance: true,
        devices: {
          where: { status: { in: ["pending_setup", "active"] } },
          orderBy: { pairedAt: "desc" },
          select: {
            deviceName: true,
            status: true,
            lastSeenAt: true,
            statusReports: {
              orderBy: [{ observedAt: "desc" }, { receivedAt: "desc" }],
              select: {
                observedAt: true,
                authorizationStatus: true,
                managedAppCount: true,
                controlStatus: true,
                lastAppliedPolicyVersion: true,
                pendingSettlementCount: true
              },
              take: 1
            }
          }
        },
        earnedSessions: {
          where: { state: "active" },
          orderBy: { startedAt: "desc" },
          select: {
            id: true,
            requestedDurationSeconds: true,
            startedAt: true,
            expiresAt: true
          },
          take: 1
        },
        appRequests: {
          where: { status: "pending" },
          select: { id: true }
        },
        submissions: {
          where: { status: "pending" },
          select: { id: true }
        },
        policyVersions: {
          orderBy: { version: "desc" },
          select: { version: true },
          take: 1
        }
      }
    });

    const homeChildren = children.map((child) => {
      const pendingDevice = child.devices.find(
        (device) => device.status === "pending_setup"
      );
      const activeDevice = child.devices.find(
        (device) => device.status === "active"
      );
      const device = pendingDevice ?? activeDevice;
      const session = child.earnedSessions[0];
      return {
        id: child.id,
        name: child.name,
        balanceSeconds: balanceSeconds(child.creditBalance),
        ...(device === undefined
          ? {}
          : {
              activeDeviceName: device.deviceName,
              deviceStatus: device.status as "pending_setup" | "active",
              ...(device.lastSeenAt === null
                ? {}
                : { lastSyncedAt: device.lastSeenAt.toISOString() })
            }),
        setupStatus: device === undefined
          ? "no_device" as const
          : pendingDevice === undefined
            ? "ready" as const
            : "pending_setup" as const,
        ...(session === undefined
          ? {}
          : {
              activeSession: {
                id: session.id,
                requestedDurationSeconds: session.requestedDurationSeconds,
                startedAt: session.startedAt.toISOString(),
                expiresAt: session.expiresAt.toISOString()
              }
            }),
        pendingAppRequestCount: child.appRequests.length,
        pendingReadingCount: child.submissions.length
      };
    });

    return {
      children: homeChildren,
      pendingRequestCount: homeChildren.reduce(
        (total, child) => total + child.pendingAppRequestCount +
          child.pendingReadingCount,
        0
      ),
      deviceAttentionCount: children.filter((child) => {
        const pendingDevice = child.devices.find(
          (device) => device.status === "pending_setup"
        );
        const activeDevice = child.devices.find(
          (device) => device.status === "active"
        );
        const device = pendingDevice ?? activeDevice;
        if (device === undefined || pendingDevice !== undefined) return true;
        const report = device.statusReports[0];
        if (report === undefined) return true;
        const latestPolicyVersion = child.policyVersions[0]?.version ?? 0n;
        const hasMatchingActiveSession = child.earnedSessions[0] !== undefined;
        return (
          (this.options.now?.() ?? Date.now()) - report.observedAt.getTime() >
            deviceStatusStaleAfterMs ||
          report.authorizationStatus !== "approved" ||
          report.managedAppCount === 0 ||
          report.controlStatus === "unknown" ||
          report.controlStatus === "policy_application_failed" ||
          (report.controlStatus === "unlocked_for_session" &&
            !hasMatchingActiveSession) ||
          report.lastAppliedPolicyVersion !== latestPolicyVersion ||
          report.pendingSettlementCount > 0
        );
      }).length
    };
  }

  async familyPreferences(user: ParentUser): Promise<FamilyPreferences> {
    const family = await this.ensureFamily(user);
    const preferences = await this.prisma.familyPreference.upsert({
      where: { familyId: family.id },
      update: {},
      create: { familyId: family.id }
    });
    return publicFamilyPreferences(preferences);
  }

  async parentPreferences(user: ParentUser): Promise<ParentPreferences> {
    const preferences = await this.prisma.parentPreference.upsert({
      where: { userId: user.id },
      update: {},
      create: { userId: user.id }
    });
    return publicParentPreferences(preferences);
  }

  async updateParentPreferences(
    user: ParentUser,
    input: UpdateParentPreferences
  ): Promise<ParentPreferences> {
    const preferences = await this.prisma.parentPreference.upsert({
      where: { userId: user.id },
      create: { userId: user.id, ...input },
      update: input
    });
    return publicParentPreferences(preferences);
  }

  async updateFamilyPreferences(
    user: ParentUser,
    input: UpdateFamilyPreferences
  ): Promise<FamilyPreferences> {
    const family = await this.ensureFamily(user);
    const presets = [...input.sessionPresetSeconds].sort((left, right) => left - right);
    return this.prisma.$transaction(async (transaction) => {
      await transaction.$executeRaw`
        SELECT pg_advisory_xact_lock(
          hashtextextended(${"family-preferences:" + family.id}, 0)
        )
      `;
      await transaction.familyPreference.upsert({
        where: { familyId: family.id },
        update: {},
        create: { familyId: family.id }
      });
      const updated = await transaction.familyPreference.updateMany({
        where: { familyId: family.id, version: input.expectedVersion },
        data: {
          defaultReadingRewardSeconds: input.defaultReadingRewardSeconds,
          sessionPresetSeconds: presets,
          updatedByUserId: user.id,
          version: { increment: 1 }
        }
      });
      if (updated.count === 0) {
        throw new ApiError(
          409,
          "stale_preferences",
          "Family settings changed on another device. Reload and try again"
        );
      }
      return publicFamilyPreferences(
        await transaction.familyPreference.findUniqueOrThrow({
          where: { familyId: family.id }
        })
      );
    });
  }

  async creditLedger(
    user: ParentUser,
    childProfileId: string,
    input: { cursor?: string; limit: number }
  ): Promise<CreditLedgerResponse> {
    const family = await this.ensureFamily(user);
    const child = await this.prisma.childProfile.findFirst({
      where: {
        id: childProfileId,
        familyId: family.id,
        status: { in: ["active", "archived"] }
      },
      select: { id: true }
    });
    if (child === null) {
      throw new ApiError(404, "child_not_found", "The child profile does not exist");
    }

    let beforeRevision: bigint | undefined;
    if (input.cursor !== undefined) {
      const cursor = await this.prisma.creditLedgerEntry.findFirst({
        where: {
          id: input.cursor,
          childProfileId
        },
        select: { ledgerRevision: true }
      });
      if (cursor === null) {
        throw new ApiError(400, "invalid_cursor", "The ledger cursor is invalid");
      }
      beforeRevision = cursor.ledgerRevision;
    }

    const records = await this.prisma.creditLedgerEntry.findMany({
      where: {
        childProfileId,
        ...(beforeRevision === undefined
          ? {}
          : { ledgerRevision: { lt: beforeRevision } })
      },
      orderBy: { ledgerRevision: "desc" },
      take: input.limit + 1
    });
    const hasNextPage = records.length > input.limit;
    const page = records.slice(0, input.limit);
    return {
      entries: page.map((entry) => ({
        id: entry.id,
        childProfileId: entry.childProfileId,
        ledgerRevision: safeInteger(entry.ledgerRevision, "ledger revision"),
        entryType: entry.entryType as CreditLedgerResponse["entries"][number]["entryType"],
        amountSeconds: safeInteger(entry.amountSeconds, "ledger amount"),
        balanceAfterSeconds: safeInteger(
          entry.balanceAfterSeconds,
          "ledger balance"
        ),
        ...(entry.reason === null ? {} : { reason: entry.reason }),
        createdAt: entry.createdAt.toISOString()
      })),
      ...(hasNextPage && page.at(-1) !== undefined
        ? { nextCursor: page.at(-1)!.id }
        : {})
    };
  }

  async createChild(user: ParentUser, name: string): Promise<Child> {
    const family = await this.ensureFamily(user);
    const child = await this.prisma.childProfile.create({
      data: {
        familyId: family.id,
        name,
        createdByUserId: user.id
      }
    });

    return {
      id: child.id,
      name: child.name,
      balanceSeconds: 0
    };
  }

  async updateChild(
    user: ParentUser,
    childProfileId: string,
    name: string
  ): Promise<Child> {
    const family = await this.ensureFamily(user);
    const updated = await this.prisma.childProfile.updateMany({
      where: {
        id: childProfileId,
        familyId: family.id,
        status: "active"
      },
      data: { name }
    });
    if (updated.count === 0) {
      throw new ApiError(404, "child_not_found", "The child profile does not exist");
    }
    const child = await this.prisma.childProfile.findUniqueOrThrow({
      where: { id: childProfileId },
      include: {
        creditBalance: true,
        devices: {
          where: { status: "active" },
          orderBy: { pairedAt: "desc" },
          select: { deviceName: true },
          take: 1
        }
      }
    });
    return {
      id: child.id,
      name: child.name,
      balanceSeconds: balanceSeconds(child.creditBalance),
      ...(child.devices[0] === undefined
        ? {}
        : { activeDeviceName: child.devices[0].deviceName })
    };
  }

  async archiveChild(
    user: ParentUser,
    childProfileId: string
  ): Promise<void> {
    const family = await this.ensureFamily(user);
    const now = new Date(this.options.now?.() ?? Date.now());
    await this.prisma.$transaction(async (transaction) => {
      await transaction.$executeRaw`
        SELECT pg_advisory_xact_lock(
          hashtextextended(${`pairing-child:${childProfileId}`}, 0)
        )
      `;
      await transaction.$executeRaw`
        SELECT pg_advisory_xact_lock(
          hashtextextended(${`app-policy:${childProfileId}`}, 0)
        )
      `;
      await transaction.$executeRaw`
        SELECT pg_advisory_xact_lock(
          hashtextextended(${`credit-child:${childProfileId}`}, 0)
        )
      `;
      const child = await transaction.childProfile.findFirst({
        where: { id: childProfileId, familyId: family.id },
        select: { status: true }
      });
      if (child === null) {
        throw new ApiError(404, "child_not_found", "The child profile does not exist");
      }
      if (child.status === "archived") return;
      if (child.status !== "active") {
        throw new ApiError(409, "child_not_active", "The child profile is not active");
      }
      const unsettledSession = await transaction.earnedTimeSession.findFirst({
        where: {
          childProfileId,
          state: { in: ["prepared", "active", "settlement_pending"] }
        },
        select: { id: true }
      });
      if (unsettledSession !== null) {
        throw new ApiError(
          409,
          "unsettled_session_exists",
          "Stop and sync Earned Time before archiving this child"
        );
      }
      const devices = await transaction.device.findMany({
        where: { childProfileId },
        select: { id: true }
      });
      const deviceIds = devices.map((device) => device.id);
      const pendingMedia = await transaction.mediaObject.findMany({
        where: {
          childProfileId,
          completedAt: null,
          deletedAt: null
        },
        select: {
          storageKey: true,
          uploadExpiresAt: true,
          completedAt: true,
          createdAt: true
        }
      });
      if (pendingMedia.length > 0) {
        await enqueueMediaDeletionJobs(transaction, pendingMedia, now);
        await transaction.mediaObject.updateMany({
          where: {
            childProfileId,
            completedAt: null,
            deletedAt: null
          },
          data: { uploadStatus: "deleted", deletedAt: now }
        });
      }
      await transaction.pairingSession.updateMany({
        where: { childProfileId, invalidatedAt: null, consumedAt: null },
        data: { invalidatedAt: now }
      });
      if (deviceIds.length > 0) {
        await transaction.device.updateMany({
          where: {
            id: { in: deviceIds },
            status: { in: ["pending_setup", "active"] }
          },
          data: { status: "revoked", revokedAt: now }
        });
        await transaction.deviceCredential.updateMany({
          where: { deviceId: { in: deviceIds }, revokedAt: null },
          data: { revokedAt: now }
        });
        await transaction.childPushDevice.updateMany({
          where: { deviceId: { in: deviceIds }, revokedAt: null },
          data: { revokedAt: now }
        });
      }
      await transaction.managedApp.updateMany({
        where: { childProfileId, archivedAt: null },
        data: {
          archivedAt: now,
          tokenCiphertext: Buffer.from(new Uint8Array())
        }
      });
      await transaction.appRequest.updateMany({
        where: { childProfileId, status: "pending" },
        data: {
          status: "decided",
          requestVersion: { increment: 1 },
          decision: null,
          decidedAt: now
        }
      });
      await transaction.pushOutboxEvent.updateMany({
        where: {
          childProfileId,
          state: { in: ["pending", "processing"] }
        },
        data: { state: "failed", lastError: "child_archived" }
      });
      await transaction.childProfile.update({
        where: { id: childProfileId },
        data: { status: "archived", archivedAt: now }
      });
    });
  }

  async claimLegacyData(
    user: ParentUser,
    input: ClaimLocalDataRequest
  ): Promise<ClaimLocalDataResponse> {
    const pepper = this.options.legacyMigrationPepper;
    if (pepper === undefined) {
      throw new ApiError(
        503,
        "legacy_migration_unavailable",
        "Legacy family import is unavailable"
      );
    }
    const proofHash = keyedHash(
      Buffer.isBuffer(pepper) ? pepper : Buffer.from(pepper, "utf8"),
      "parent-credential",
      input.localParentToken
    );
    const now = new Date(this.options.now?.() ?? Date.now());

    return this.prisma.$transaction(async (transaction) => {
      const states = await transaction.$queryRaw<LegacyClaimState[]>`
        SELECT
          parent_token_hash,
          local_data_claimed_parent_id::text,
          local_data_migrated_family_id::text,
          local_data_migrated_children
        FROM server_state
        WHERE singleton = true
        FOR UPDATE
      `;
      const state = states[0];
      if (state === undefined) {
        throw new Error("PagePass server state is missing");
      }
      if (!constantHashEqual(proofHash, Buffer.from(state.parent_token_hash))) {
        throw new ApiError(
          401,
          "invalid_local_parent_token",
          "The legacy local parent token is invalid"
        );
      }

      if (state.local_data_migrated_family_id !== null) {
        const existingMembership = await transaction.familyMember.findFirst({
          where: {
            userId: user.id,
            familyId: state.local_data_migrated_family_id,
            status: "active",
            family: { status: "active" }
          },
          select: { familyId: true }
        });
        if (existingMembership !== null) {
          return {
            claimedChildren: state.local_data_migrated_children ?? 0
          };
        }
        throw new ApiError(
          409,
          "local_data_already_claimed",
          "The legacy local data was already claimed by another family"
        );
      }

      const family = await ensureFamilyInTransaction(transaction, user);
      const legacyOwnerId = state.local_data_claimed_parent_id ?? legacyLocalParentId;
      const children = await transaction.child.findMany({
        where: { ownerParentId: legacyOwnerId },
        orderBy: { id: "asc" }
      });

      const childIds = children.map((child) => child.id);
      const activeDevices = childIds.length === 0
        ? []
        : await transaction.activeDevice.findMany({
            where: { childProfileId: { in: childIds } }
          });
      const creditGrants = childIds.length === 0
        ? []
        : await transaction.creditGrant.findMany({
            where: { childProfileId: { in: childIds } }
          });
      const earnedTimeSpends = childIds.length === 0
        ? []
        : await transaction.earnedTimeSpend.findMany({
            where: { childProfileId: { in: childIds } }
          });
      const installationIds = activeDevices.map((device) => device.installationId);
      const credentialDigests = activeDevices.map((device) =>
        Buffer.from(device.credentialHash)
      );
      const existingChildren = childIds.length === 0
        ? []
        : await transaction.childProfile.findMany({
            where: { id: { in: childIds } },
            select: { id: true }
          });
      const existingDevices = installationIds.length === 0
        ? []
        : await transaction.device.findMany({
            where: { installationId: { in: installationIds } },
            select: { installationId: true }
          });
      const existingCredentials = credentialDigests.length === 0
        ? []
        : await transaction.deviceCredential.findMany({
            where: { tokenDigest: { in: credentialDigests } },
            select: { id: true }
          });
      if (
        existingChildren.length > 0 ||
        existingDevices.length > 0 ||
        existingCredentials.length > 0
      ) {
        throw new ApiError(
          409,
          "legacy_migration_conflict",
          "Legacy family data conflicts with an existing child or device"
        );
      }

      for (const child of children) {
        const activeDevice = activeDevices.find(
          (device) => device.childProfileId === child.id
        );
        await transaction.childProfile.create({
          data: {
            id: child.id,
            familyId: family.id,
            name: child.name,
            createdByUserId: user.id,
            createdAt: now,
            updatedAt: now
          }
        });

        const orderedEvents = orderLegacyLedgerEvents([
          ...creditGrants
            .filter((grant) => grant.childProfileId === child.id)
            .map((grant): LegacyLedgerEvent => ({
            source: "grant",
            sourceId: grant.id,
            amountSeconds: BigInt(grant.seconds),
            balanceAfterSeconds: grant.balanceSeconds,
            idempotencyKey: `legacy-grant:${grant.id}`,
            requestFingerprint: grant.fingerprint,
            reason: grant.reason,
            createdAt: grant.createdAt
            })),
          ...earnedTimeSpends
            .filter((spend) => spend.childProfileId === child.id)
            .map((spend): LegacyLedgerEvent => ({
            source: "spend",
            sourceId: spend.id,
            amountSeconds: -BigInt(spend.consumedSeconds),
            balanceAfterSeconds: spend.balanceSeconds,
            idempotencyKey: `legacy-spend:${spend.id}`,
            requestFingerprint: spend.fingerprint,
            reason: "Legacy Earned Time session",
            createdAt: spend.settledAt
            }))
        ]);
        const materialEvents = orderedEvents.filter(
          (event) => event.amountSeconds !== 0n
        );
        if (materialEvents.length > 0) {
          await transaction.creditLedgerEntry.createMany({
            data: materialEvents.map((event, index) => ({
              id: randomUUID(),
              childProfileId: child.id,
              ledgerRevision: BigInt(index + 1),
              entryType: event.source === "grant" ? "parent_grant" : "session_spend",
              amountSeconds: event.amountSeconds,
              balanceAfterSeconds: event.balanceAfterSeconds,
              actorUserId: null,
              reason: event.reason,
              idempotencyKey: event.idempotencyKey,
              requestFingerprint: event.requestFingerprint,
              createdAt: event.createdAt
            }))
          });
        }
        const finalBalance = orderedEvents.at(-1)?.balanceAfterSeconds ?? 0n;
        await transaction.childCreditBalance.update({
          where: { childProfileId: child.id },
          data: {
            balanceSeconds: finalBalance,
            ledgerRevision: BigInt(materialEvents.length),
            updatedAt: now
          }
        });

        if (activeDevice !== undefined) {
          const device = await transaction.device.create({
            data: {
              childProfileId: child.id,
              installationId: activeDevice.installationId,
              deviceName: activeDevice.deviceName,
              status: "pending_setup",
              appVersion: "legacy",
              appBuild: "legacy",
              pairedAt: now,
              lastSeenAt: now,
              createdAt: now,
              updatedAt: now
            }
          });
          await transaction.deviceCredential.create({
            data: {
              deviceId: device.id,
              tokenDigest: Buffer.from(activeDevice.credentialHash),
              createdAt: now
            }
          });
        }
      }

      if (childIds.length > 0) {
        await transaction.legacyPairingSession.updateMany({
          where: {
            childProfileId: { in: childIds },
            consumedAt: null
          },
          data: { consumedAt: now }
        });
      }
      await transaction.serverState.update({
        where: { singleton: true },
        data: {
          localDataMigratedFamilyId: family.id,
          localDataMigratedChildren: children.length
        }
      });
      return { claimedChildren: children.length };
    });
  }

  async deleteParentAccount(user: ParentUser): Promise<void> {
    const now = new Date(this.options.now?.() ?? Date.now());
    if (
      user.sessionCreatedAt === undefined ||
      now.getTime() - user.sessionCreatedAt.getTime() > 10 * 60 * 1_000
    ) {
      throw new ApiError(
        403,
        "recent_sign_in_required",
        "Sign out and sign in again before deleting your account"
      );
    }

    await this.prisma.$transaction(async (transaction) => {
      await transaction.$executeRaw`
        SELECT pg_advisory_xact_lock(
          hashtextextended(${"account-delete:" + user.id}, 0)
        )
      `;
      const familyIds = (await transaction.familyMember.findMany({
        where: { userId: user.id, status: "active" },
        orderBy: { familyId: "asc" },
        select: { familyId: true }
      })).map((membership) => membership.familyId);
      for (const familyId of familyIds) {
        await transaction.$executeRaw`
          SELECT pg_advisory_xact_lock(
            hashtextextended(${`account-delete-family:${familyId}`}, 0)
          )
        `;
      }
      const memberships = await transaction.familyMember.findMany({
        where: { userId: user.id, status: "active" },
        include: {
          family: {
            include: {
              members: {
                where: { status: "active" },
                orderBy: { joinedAt: "asc" }
              }
            }
          }
        }
      });

      const soleParentFamilyIds = memberships
        .filter((membership) => membership.family.members.length === 1)
        .map((membership) => membership.familyId);
      if (soleParentFamilyIds.length > 0) {
        const childIds = (await transaction.childProfile.findMany({
          where: { familyId: { in: soleParentFamilyIds } },
          orderBy: { id: "asc" },
          select: { id: true }
        })).map((child) => child.id);
        for (const childId of childIds) {
          await transaction.$executeRaw`
            SELECT pg_advisory_xact_lock(
              hashtextextended(${`pairing-child:${childId}`}, 0)
            )
          `;
          await transaction.$executeRaw`
            SELECT pg_advisory_xact_lock(
              hashtextextended(${`app-policy:${childId}`}, 0)
            )
          `;
          await transaction.$executeRaw`
            SELECT pg_advisory_xact_lock(
              hashtextextended(${`credit-child:${childId}`}, 0)
            )
          `;
        }
        const unsettled = await transaction.earnedTimeSession.findFirst({
          where: {
            childProfile: { familyId: { in: soleParentFamilyIds } },
            state: { in: ["prepared", "active", "settlement_pending"] }
          },
          select: { id: true }
        });
        if (unsettled !== null) {
          throw new ApiError(
            409,
            "active_session_exists",
            "Stop and sync Earned Time before deleting the final parent account"
          );
        }
      }

      for (const membership of memberships) {
        const successor = membership.family.members.find(
          (member) => member.userId !== user.id
        );
        if (successor !== undefined) {
          if (membership.role === "owner") {
            await transaction.familyMember.update({
              where: {
                familyId_userId: {
                  familyId: membership.familyId,
                  userId: successor.userId
                }
              },
              data: { role: "owner" }
            });
          }
          continue;
        }
        await closeFamilyForAccountDeletion(
          transaction,
          membership.familyId,
          now
        );
      }

      await transaction.user.delete({ where: { id: user.id } });
    });
  }

  private async ensureFamily(user: ParentUser): Promise<FamilyScope> {
    return this.prisma.$transaction((transaction) =>
      ensureFamilyInTransaction(transaction, user)
    );
  }
}

async function ensureFamilyInTransaction(
  transaction: PrismaTransaction,
  user: ParentUser
): Promise<FamilyScope> {
  await transaction.$executeRaw`
    SELECT pg_advisory_xact_lock(hashtextextended(${user.id}, 0))
  `;
  const membership = await transaction.familyMember.findFirst({
    where: {
      userId: user.id,
      status: "active",
      family: { status: "active" }
    },
    orderBy: { joinedAt: "asc" },
    select: { familyId: true }
  });
  if (membership !== null) return { id: membership.familyId };

  const family = await transaction.family.create({
    data: {
      name: familyName(user.name),
      createdByUserId: user.id
    },
    select: { id: true }
  });
  await transaction.familyMember.create({
    data: {
      familyId: family.id,
      userId: user.id,
      role: "owner"
    }
  });
  return family;
}

function orderLegacyLedgerEvents(
  events: LegacyLedgerEvent[]
): LegacyLedgerEvent[] {
  const pending = [...events];
  const ordered: LegacyLedgerEvent[] = [];
  let balance = 0n;
  while (pending.length > 0) {
    const candidates = pending.filter((event) =>
      balance + event.amountSeconds === event.balanceAfterSeconds
    );
    candidates.sort(compareLegacyEvents);
    const next = candidates[0];
    if (
      next === undefined ||
      next.balanceAfterSeconds < 0n ||
      next.balanceAfterSeconds > maximumSafeInteger
    ) {
      throw new ApiError(
        409,
        "legacy_ledger_inconsistent",
        "Legacy credit history could not be migrated safely"
      );
    }
    pending.splice(pending.indexOf(next), 1);
    ordered.push(next);
    balance = next.balanceAfterSeconds;
  }
  return ordered;
}

function compareLegacyEvents(
  left: LegacyLedgerEvent,
  right: LegacyLedgerEvent
): number {
  return left.createdAt.getTime() - right.createdAt.getTime() ||
    left.source.localeCompare(right.source) ||
    left.sourceId.localeCompare(right.sourceId);
}

function keyedHash(
  pepper: Buffer,
  purpose: string,
  value: string
): Buffer {
  return createHmac("sha256", pepper)
    .update(purpose)
    .update("\0")
    .update(value)
    .digest();
}

function constantHashEqual(left: Buffer, right: Buffer): boolean {
  return left.length === right.length && timingSafeEqual(left, right);
}

async function closeFamilyForAccountDeletion(
  transaction: PrismaTransaction,
  familyId: string,
  now: Date
): Promise<void> {
  const children = await transaction.childProfile.findMany({
    where: { familyId },
    select: { id: true }
  });
  const childIds = children.map((child) => child.id);
  if (childIds.length > 0) {
    const media = await transaction.mediaObject.findMany({
      where: { childProfileId: { in: childIds }, deletedAt: null },
      select: {
        storageKey: true,
        uploadExpiresAt: true,
        completedAt: true,
        createdAt: true
      }
    });
    if (media.length > 0) {
      await enqueueMediaDeletionJobs(transaction, media, now);
    }
    await transaction.mediaObject.updateMany({
      where: { childProfileId: { in: childIds }, deletedAt: null },
      data: { deletedAt: now }
    });
    await transaction.readingEvidence.updateMany({
      where: { childProfileId: { in: childIds } },
      data: { rawOcrText: null, ocrLanguageCodes: [] }
    });
    await transaction.readingSubmission.updateMany({
      where: { childProfileId: { in: childIds } },
      data: {
        bookTitle: null,
        author: null,
        correctedOcrText: null,
        coverMediaId: null
      }
    });
    await transaction.submissionReview.updateMany({
      where: { childProfileId: { in: childIds } },
      data: { comment: null }
    });
    await transaction.appRequest.updateMany({
      where: { childProfileId: { in: childIds } },
      data: { message: null }
    });
    await transaction.appRequest.updateMany({
      where: { childProfileId: { in: childIds }, status: "pending" },
      data: {
        status: "decided",
        decision: "denied",
        decidedAt: now,
        requestVersion: { increment: 1 }
      }
    });
    await transaction.managedApp.updateMany({
      where: { childProfileId: { in: childIds }, archivedAt: null },
      data: { archivedAt: now, tokenCiphertext: Buffer.from(new Uint8Array()) }
    });
    await transaction.pairingSession.updateMany({
      where: {
        childProfileId: { in: childIds },
        invalidatedAt: null,
        consumedAt: null
      },
      data: { invalidatedAt: now }
    });
    await transaction.deviceCredential.updateMany({
      where: {
        device: { childProfileId: { in: childIds } },
        revokedAt: null
      },
      data: { revokedAt: now }
    });
    await transaction.childPushDevice.updateMany({
      where: { childProfileId: { in: childIds }, revokedAt: null },
      data: { revokedAt: now }
    });
    await transaction.device.updateMany({
      where: {
        childProfileId: { in: childIds },
        status: { in: ["pending_setup", "active"] }
      },
      data: { status: "revoked", revokedAt: now }
    });
    await transaction.childProfile.updateMany({
      where: { id: { in: childIds } },
      data: { name: "Deleted Child", status: "archived", archivedAt: now }
    });
  }
  await transaction.pushOutboxEvent.updateMany({
    where: { familyId, state: { in: ["pending", "processing"] } },
    data: { state: "failed", lastError: "family_account_deleted" }
  });
  await transaction.family.update({
    where: { id: familyId },
    data: { name: "Deleted Family", status: "archived" }
  });
}

async function enqueueMediaDeletionJobs(
  transaction: PrismaTransaction,
  media: Array<{
    storageKey: string;
    uploadExpiresAt: Date | null;
    completedAt: Date | null;
    createdAt: Date;
  }>,
  now: Date
): Promise<void> {
  const continuousMedia = media.filter((item) =>
    item.completedAt === null || item.uploadExpiresAt !== null
  );
  const completedMedia = media.filter((item) =>
    item.completedAt !== null && item.uploadExpiresAt === null
  );
  if (completedMedia.length > 0) {
    await transaction.mediaDeletionJob.createMany({
      data: completedMedia.map((item) => ({
        storageKey: item.storageKey,
        nextAttemptAt: now
      })),
      skipDuplicates: true
    });
  }
  for (const item of continuousMedia) {
    const expiresAt = item.uploadExpiresAt
      ?? new Date(item.createdAt.getTime() + 15 * 60 * 1_000);
    const nextAttemptAt = item.completedAt === null
      ? new Date(Math.max(now.getTime(), expiresAt.getTime() + 60 * 1_000))
      : now;
    await transaction.mediaDeletionJob.upsert({
      where: { storageKey: item.storageKey },
      create: {
        storageKey: item.storageKey,
        continuousVerification: true,
        nextAttemptAt
      },
      update: {
        state: "pending",
        attemptCount: 0,
        continuousVerification: true,
        nextAttemptAt,
        lastError: null,
        completedAt: null
      }
    });
  }
}

function balanceSeconds(
  balance: { balanceSeconds: bigint } | null
): number {
  if (
    balance === null ||
    balance.balanceSeconds < 0n ||
    balance.balanceSeconds > BigInt(Number.MAX_SAFE_INTEGER)
  ) {
    throw new Error("Child credit balance is missing or invalid");
  }
  return Number(balance.balanceSeconds);
}

function safeInteger(value: bigint, field: string): number {
  if (
    value < BigInt(Number.MIN_SAFE_INTEGER) ||
    value > BigInt(Number.MAX_SAFE_INTEGER)
  ) {
    throw new Error(`The ${field} is outside the supported range`);
  }
  return Number(value);
}

function familyName(parentName: string): string {
  const name = parentName.trim();
  if (name.length === 0) return "PagePass Family";
  return `${name.slice(0, 91)} Family`;
}

function publicFamilyPreferences(input: {
  version: number;
  defaultReadingRewardSeconds: number;
  sessionPresetSeconds: number[];
  expirationWarningSeconds: number;
  appRequestBehavior: string;
  updatedAt: Date;
}): FamilyPreferences {
  return {
    version: input.version,
    defaultReadingRewardSeconds: input.defaultReadingRewardSeconds,
    sessionPresetSeconds: input.sessionPresetSeconds as FamilyPreferences["sessionPresetSeconds"],
    expirationWarningSeconds: input.expirationWarningSeconds,
    appRequestBehavior: "parent_approval",
    updatedAt: input.updatedAt.toISOString()
  };
}

function publicParentPreferences(input: {
  readingRequestsEnabled: boolean;
  appRequestsEnabled: boolean;
  deviceAlertsEnabled: boolean;
  sessionEndedEnabled: boolean;
  updatedAt: Date;
}): ParentPreferences {
  return {
    readingRequestsEnabled: input.readingRequestsEnabled,
    appRequestsEnabled: input.appRequestsEnabled,
    deviceAlertsEnabled: input.deviceAlertsEnabled,
    sessionEndedEnabled: input.sessionEndedEnabled,
    updatedAt: input.updatedAt.toISOString()
  };
}
import { Buffer } from "node:buffer";
