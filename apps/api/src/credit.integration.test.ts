import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import test from "node:test";

import {
  createBetterAuth,
  createBetterAuthFastifyHandler
} from "./auth/better-auth.js";
import type { ApiEnv } from "./config/env.js";
import { PrismaCreditService } from "./credit/credit-service.js";
import { createPrismaClient } from "./db/prisma.js";
import { PrismaFamilyService } from "./family/family-service.js";
import { createBetterAuthParentApi } from "./family/parent-api.js";
import { createFastifyServer } from "./fastify-server.js";
import { PrismaPairingService } from "./pairing/pairing-service.js";
import { PostgresPagePassStore } from "./postgres-store.js";

const databaseUrl = process.env.TEST_DATABASE_URL;
const password = "correct horse battery staple";

test(
  "Better Auth credit ledger grants and settles one-shot earned time atomically",
  { skip: databaseUrl === undefined ? "TEST_DATABASE_URL is not set" : false },
  async () => {
    assert.ok(databaseUrl !== undefined);
    const prisma = createPrismaClient(databaseUrl);
    const database = await prisma.$queryRaw<Array<{ name: string }>>`
      SELECT current_database() AS name
    `;
    assert.match(database[0]?.name ?? "", /_test$/);
    await prisma.$executeRawUnsafe(`
      TRUNCATE TABLE
        credit_ledger_entries,
        earned_time_sessions,
        child_credit_balances,
        parent_sessions,
        apple_auth_challenges,
        pairing_rate_attempts,
        earned_time_spends,
        credit_grants,
        active_devices,
        legacy_pairing_sessions,
        children,
        device_credentials,
        pairing_sessions,
        devices,
        child_profiles,
        family_members,
        families,
        accounts,
        sessions,
        verifications,
        users,
        server_state,
        parent_accounts
      CASCADE
    `);
    await prisma.parentAccount.create({
      data: {
        id: "00000000-0000-4000-8000-000000000001",
        issuer: "pagepass:local",
        subject: "default",
        displayName: "Local Parent",
        createdAt: new Date()
      }
    });

    const pepper = "credit-integration-pepper";
    const legacyStore = await PostgresPagePassStore.create({
      databaseUrl,
      parentToken: "credit-integration-legacy-parent",
      pepper
    });
    const env: ApiEnv = {
      nodeEnv: "test",
      authMode: "local",
      databaseUrl,
      betterAuthSecret: "credit-integration-secret-at-least-32",
      betterAuthUrl: "http://localhost:8787",
      trustedOrigins: ["pagepass://auth"],
      resendApiKey: undefined,
      emailFrom: "PagePass <no-reply@example.com>",
      appleClientId: undefined,
      appleClientSecret: undefined
    };
    const auth = createBetterAuth({
      prisma,
      env,
      sendEmail: async () => undefined
    });
    let now = Date.parse("2026-07-27T12:00:00.000Z");
    const pairing = new PrismaPairingService(prisma, {
      pepper,
      now: () => now,
      legacy: legacyStore
    });
    const credit = new PrismaCreditService(prisma, {
      pepper,
      now: () => now,
      legacy: legacyStore
    });
    const parentApi = createBetterAuthParentApi({
      auth,
      families: new PrismaFamilyService(prisma),
      pairing
    });
    const server = createFastifyServer({
      trustedOrigins: env.trustedOrigins,
      authHandler: createBetterAuthFastifyHandler(auth),
      parentApi,
      pairingApi: pairing,
      creditApi: credit,
      logger: false,
      legacyHandler: async (_request, response) => {
        response.writeHead(404);
        response.end();
      }
    });

    async function createParent(name: string) {
      const email = `${name.toLowerCase()}-${randomUUID()}@example.com`;
      await auth.api.signUpEmail({
        body: { name, email, password }
      });
      const user = await prisma.user.findUniqueOrThrow({ where: { email } });
      await prisma.user.update({
        where: { id: user.id },
        data: { emailVerified: true }
      });
      const login = await auth.api.signInEmail({
        body: { email, password }
      });
      assert.ok(login.token);
      return { user, token: login.token };
    }

    const parentRequest = (
      token: string,
      options: {
        method?: "GET" | "POST";
        url: string;
        payload?: unknown;
      }
    ) => server.inject({
      method: options.method ?? "GET",
      url: options.url,
      headers: { authorization: `Bearer ${token}` },
      ...(options.payload === undefined ? {} : { payload: options.payload })
    });
    const childRequest = (
      credential: string,
      options: {
        method?: "GET" | "POST" | "PUT";
        url: string;
        payload?: unknown;
      }
    ) => server.inject({
      method: options.method ?? "GET",
      url: options.url,
      headers: { authorization: `Bearer ${credential}` },
      ...(options.payload === undefined ? {} : { payload: options.payload })
    });

    async function recordAppliedSetupPolicy(installationId: string) {
      const device = await prisma.device.findUniqueOrThrow({
        where: { installationId }
      });
      const latest = await prisma.childPolicyVersion.findFirst({
        where: { childProfileId: device.childProfileId },
        orderBy: { version: "desc" },
        select: { version: true }
      });
      const version = (latest?.version ?? 0n) + 1n;
      const policyVersion = await prisma.childPolicyVersion.create({
        data: {
          childProfileId: device.childProfileId,
          version,
          source: "test_setup",
          idempotencyKey: `test-setup:${device.id}`,
          requestFingerprint: randomUUID()
        }
      });
      await prisma.managedApp.create({
        data: {
          childProfileId: device.childProfileId,
          sourceDeviceId: device.id,
          clientAppId: `test-app:${device.id}`,
          tokenCiphertext: Buffer.from("test-token"),
          tokenDigest: Buffer.from(randomUUID()),
          tokenFormatVersion: 1,
          currentPolicy: "earned_time",
          currentPolicyVersion: version
        }
      });
      await prisma.policyApplicationAck.create({
        data: {
          childProfileId: device.childProfileId,
          policyVersion: version,
          deviceId: device.id,
          result: "applied",
          appliedAt: new Date(now),
          reportedAt: new Date(now)
        }
      });
      return policyVersion;
    }

    try {
      const firstParent = await createParent("first");
      const childResponse = await parentRequest(firstParent.token, {
        method: "POST",
        url: "/v1/parent/children",
        payload: { name: "Ada" }
      });
      assert.equal(childResponse.statusCode, 201);
      const childProfileId = childResponse.json().id as string;
      assert.equal(await prisma.childCreditBalance.count(), 1);

      const grantInput = {
        seconds: 1_800,
        reason: "Reading reward",
        idempotencyKey: randomUUID()
      };
      const grants = await Promise.all(
        Array.from({ length: 10 }, () =>
          parentRequest(firstParent.token, {
            method: "POST",
            url: `/v1/parent/children/${childProfileId}/credit-grants`,
            payload: grantInput
          })
        )
      );
      assert.ok(grants.every((response) => response.statusCode === 200));
      assert.equal(new Set(grants.map((response) => response.json().id)).size, 1);
      assert.equal(grants[0]?.json().balanceSeconds, 1_800);
      assert.equal(grants[0]?.json().ledgerRevision, 1);
      assert.equal(await prisma.creditLedgerEntry.count(), 1);

      const secondParent = await createParent("second");
      const crossFamilyGrant = await parentRequest(secondParent.token, {
        method: "POST",
        url: `/v1/parent/children/${childProfileId}/credit-grants`,
        payload: {
          seconds: 60,
          reason: "Should fail",
          idempotencyKey: randomUUID()
        }
      });
      assert.equal(crossFamilyGrant.statusCode, 404);

      const children = await parentRequest(firstParent.token, {
        url: "/v1/parent/children"
      });
      assert.equal(children.json().children[0].balanceSeconds, 1_800);

      const pairingSession = await parentRequest(firstParent.token, {
        method: "POST",
        url: `/v1/parent/children/${childProfileId}/pairing-sessions`,
        payload: {}
      });
      assert.equal(pairingSession.statusCode, 201);
      const installationId = randomUUID();
      const paired = await server.inject({
        method: "POST",
        url: "/v1/pairing/consume",
        payload: {
          installationId,
          deviceName: "Ada iPhone",
          appVersion: "1.0.0",
          appBuild: "1",
          qrToken: pairingSession.json().qrToken
        }
      });
      assert.equal(paired.statusCode, 200);
      await recordAppliedSetupPolicy(installationId);
      assert.equal(paired.json().child.balanceSeconds, 1_800);
      const credential = paired.json().deviceCredential as string;
      const pendingSnapshot = await childRequest(credential, {
        url: "/v1/child/snapshot"
      });
      assert.equal(pendingSnapshot.json().balanceSeconds, 1_800);
      assert.equal(pendingSnapshot.json().ledgerRevision, 1);

      const pendingSessionId = randomUUID();
      const pendingStart = await childRequest(credential, {
        method: "POST",
        url: `/v1/child/earned-time-sessions/${pendingSessionId}/start`,
        payload: {
          requestedDurationSeconds: 900,
          balanceBeforeSeconds: 1_800
        }
      });
      assert.equal(pendingStart.statusCode, 401);

      const completedSetup = await childRequest(credential, {
        method: "POST",
        url: "/v1/child/setup/complete",
        payload: {
          authorizationStatus: "approved",
          earnedTimeAppCount: 1,
          shieldStatus: "locked"
        }
      });
      assert.equal(completedSetup.statusCode, 200);
      assert.equal(completedSetup.json().deviceStatus, "active");
      const unstarted = settlement({
        localSessionId: randomUUID()
      });
      const unstartedResult = await childRequest(credential, {
        method: "PUT",
        url: `/v1/child/earned-time-sessions/${unstarted.localSessionId}`,
        payload: unstarted
      });
      assert.equal(unstartedResult.statusCode, 409);
      assert.equal(unstartedResult.json().error.code, "session_not_started");

      const abandonedSessionId = randomUUID();
      const abandonedStart = await childRequest(credential, {
        method: "POST",
        url: `/v1/child/earned-time-sessions/${abandonedSessionId}/start`,
        payload: {
          requestedDurationSeconds: 900,
          balanceBeforeSeconds: 1_800
        }
      });
      assert.equal(abandonedStart.statusCode, 200);
      const pairedDevice = await prisma.device.findUniqueOrThrow({
        where: { installationId }
      });
      const revokeWithPendingSettlement = await parentRequest(
        firstParent.token,
        {
          method: "POST",
          url: `/v1/parent/children/${childProfileId}/devices/${pairedDevice.id}/revoke`,
          payload: {}
        }
      );
      assert.equal(revokeWithPendingSettlement.statusCode, 409);
      assert.equal(
        revokeWithPendingSettlement.json().error.code,
        "active_session_exists"
      );

      const manualSessionId = randomUUID();
      const starts = await Promise.all(
        Array.from({ length: 10 }, () =>
          childRequest(credential, {
            method: "POST",
            url: `/v1/child/earned-time-sessions/${manualSessionId}/start`,
            payload: {
              requestedDurationSeconds: 900,
              balanceBeforeSeconds: 1_800
            }
          })
        )
      );
      assert.ok(starts.every((response) => response.statusCode === 200));
      assert.deepEqual(
        new Set(starts.map((response) => JSON.stringify(response.json()))).size,
        1
      );
      assert.equal(
        (
          await prisma.earnedTimeSession.findFirstOrThrow({
            where: { localSessionId: abandonedSessionId }
          })
        ).state,
        "cancelled"
      );
      const manualStart = starts[0]!.json();
      now += 300_000;
      const manualActivation = await childRequest(credential, {
        method: "POST",
        url: `/v1/child/earned-time-sessions/${manualSessionId}/activate`,
        payload: {}
      });
      assert.equal(manualActivation.statusCode, 200);
      assert.equal(
        manualActivation.json().requestedDurationSeconds,
        manualStart.requestedDurationSeconds
      );
      assert.notEqual(manualActivation.json().startedAt, manualStart.startedAt);
      now += 300_100;
      const offlineStoppedAt = new Date(now).toISOString();
      now += 360_000;
      const manualSettlement = settlementFromStart(manualActivation.json(), {
        endedAt: offlineStoppedAt,
        consumedSeconds: 0
      });
      const futureSettlement = await childRequest(credential, {
        method: "PUT",
        url: `/v1/child/earned-time-sessions/${manualSettlement.localSessionId}`,
        payload: {
          ...manualSettlement,
          endedAt: new Date(now + 30_001).toISOString(),
          idempotencyKey: randomUUID()
        }
      });
      assert.equal(futureSettlement.statusCode, 422);
      assert.equal(
        futureSettlement.json().error.code,
        "settlement_ended_at_in_future"
      );
      const settlements = await Promise.all(
        Array.from({ length: 10 }, () =>
          childRequest(credential, {
            method: "PUT",
            url: `/v1/child/earned-time-sessions/${manualSettlement.localSessionId}`,
            payload: manualSettlement
          })
        )
      );
      assert.ok(settlements.every((response) => response.statusCode === 200));
      assert.equal(
        new Set(settlements.map((response) => response.json().id)).size,
        1
      );
      assert.equal(settlements[0]?.json().consumedSeconds, 301);
      assert.equal(settlements[0]?.json().balanceSeconds, 1_499);
      assert.equal(await prisma.earnedTimeSession.count(), 2);
      assert.equal(await prisma.creditLedgerEntry.count(), 2);

      const changedRetry = await childRequest(credential, {
        method: "PUT",
        url: `/v1/child/earned-time-sessions/${manualSettlement.localSessionId}`,
        payload: { ...manualSettlement, endedAt: "2026-07-27T12:06:00.000Z" }
      });
      assert.equal(changedRetry.statusCode, 409);
      assert.equal(changedRetry.json().error.code, "idempotency_conflict");
      const changedKey = await childRequest(credential, {
        method: "PUT",
        url: `/v1/child/earned-time-sessions/${manualSettlement.localSessionId}`,
        payload: { ...manualSettlement, idempotencyKey: randomUUID() }
      });
      assert.equal(changedKey.statusCode, 409);
      assert.equal(changedKey.json().error.code, "session_already_settled");

      const expiredSessionId = randomUUID();
      const expiredStartResponse = await childRequest(credential, {
        method: "POST",
        url: `/v1/child/earned-time-sessions/${expiredSessionId}/start`,
        payload: {
          requestedDurationSeconds: 900,
          balanceBeforeSeconds: 1_499
        }
      });
      assert.equal(expiredStartResponse.statusCode, 200);
      const expiredActivation = await childRequest(credential, {
        method: "POST",
        url: `/v1/child/earned-time-sessions/${expiredSessionId}/activate`,
        payload: {}
      });
      assert.equal(expiredActivation.statusCode, 200);
      const expiredSettlement = settlementFromStart(
        expiredStartResponse.json(),
        {
          endReason: "expired",
          endedAt: expiredStartResponse.json().expiresAt,
          consumedSeconds: 900
        }
      );
      const earlyExpiry = await childRequest(credential, {
        method: "PUT",
        url: `/v1/child/earned-time-sessions/${expiredSessionId}`,
        payload: expiredSettlement
      });
      assert.equal(earlyExpiry.statusCode, 422);
      assert.equal(earlyExpiry.json().error.code, "session_not_expired");
      now += 900_000;
      const expiredResult = await childRequest(credential, {
        method: "PUT",
        url: `/v1/child/earned-time-sessions/${expiredSessionId}`,
        payload: expiredSettlement
      });
      assert.equal(expiredResult.statusCode, 200);
      assert.equal(expiredResult.json().consumedSeconds, 900);
      assert.equal(expiredResult.json().balanceSeconds, 599);

      const zeroSessionId = randomUUID();
      const zeroStartResponse = await childRequest(credential, {
        method: "POST",
        url: `/v1/child/earned-time-sessions/${zeroSessionId}/start`,
        payload: {
          requestedDurationSeconds: 299,
          balanceBeforeSeconds: 599
        }
      });
      assert.equal(zeroStartResponse.statusCode, 400);
      const validZeroStartResponse = await childRequest(credential, {
        method: "POST",
        url: `/v1/child/earned-time-sessions/${zeroSessionId}/start`,
        payload: {
          requestedDurationSeconds: 900,
          balanceBeforeSeconds: 900
        }
      });
      assert.equal(validZeroStartResponse.statusCode, 422);
      const zeroGrant = await parentRequest(firstParent.token, {
        method: "POST",
        url: `/v1/parent/children/${childProfileId}/credit-grants`,
        payload: {
          seconds: 301,
          reason: "Minimum session top-up",
          idempotencyKey: randomUUID()
        }
      });
      assert.equal(zeroGrant.statusCode, 200);
      const zeroStarted = await childRequest(credential, {
        method: "POST",
        url: `/v1/child/earned-time-sessions/${zeroSessionId}/start`,
        payload: {
          requestedDurationSeconds: 900,
          balanceBeforeSeconds: 900
        }
      });
      assert.equal(zeroStarted.statusCode, 200);
      const zeroActivation = await childRequest(credential, {
        method: "POST",
        url: `/v1/child/earned-time-sessions/${zeroSessionId}/activate`,
        payload: {}
      });
      assert.equal(zeroActivation.statusCode, 200);
      const zeroSettlement = settlementFromStart(zeroStarted.json(), {
        idempotencyKey: randomUUID(),
        endedAt: zeroStarted.json().startedAt,
        consumedSeconds: 0
      });
      const zeroResult = await childRequest(credential, {
        method: "PUT",
        url: `/v1/child/earned-time-sessions/${zeroSettlement.localSessionId}`,
        payload: zeroSettlement
      });
      assert.equal(zeroResult.statusCode, 200);
      assert.equal(zeroResult.json().consumedSeconds, 0);
      assert.equal(zeroResult.json().balanceSeconds, 900);

      const laterGrant = await parentRequest(firstParent.token, {
        method: "POST",
        url: `/v1/parent/children/${childProfileId}/credit-grants`,
        payload: {
          seconds: 1,
          reason: "Later reward",
          idempotencyKey: randomUUID()
        }
      });
      assert.equal(laterGrant.statusCode, 200);
      const zeroRetry = await childRequest(credential, {
        method: "PUT",
        url: `/v1/child/earned-time-sessions/${zeroSettlement.localSessionId}`,
        payload: zeroSettlement
      });
      assert.deepEqual(zeroRetry.json(), zeroResult.json());
      const reusedZeroKey = await parentRequest(firstParent.token, {
        method: "POST",
        url: `/v1/parent/children/${childProfileId}/credit-grants`,
        payload: {
          seconds: 1,
          reason: "Must conflict",
          idempotencyKey: zeroSettlement.idempotencyKey
        }
      });
      assert.equal(reusedZeroKey.statusCode, 409);
      assert.equal(reusedZeroKey.json().error.code, "idempotency_conflict");

      const orphanedSessionId = randomUUID();
      const orphanedStart = await childRequest(credential, {
        method: "POST",
        url: `/v1/child/earned-time-sessions/${orphanedSessionId}/start`,
        payload: {
          requestedDurationSeconds: 900,
          balanceBeforeSeconds: 901
        }
      });
      assert.equal(orphanedStart.statusCode, 200);
      const orphanedActivation = await childRequest(credential, {
        method: "POST",
        url: `/v1/child/earned-time-sessions/${orphanedSessionId}/activate`,
        payload: {}
      });
      assert.equal(orphanedActivation.statusCode, 200);

      const sameInstallationPairing = await parentRequest(firstParent.token, {
        method: "POST",
        url: `/v1/parent/children/${childProfileId}/pairing-sessions`,
        payload: {}
      });
      const blockedSameInstallation = await server.inject({
        method: "POST",
        url: "/v1/pairing/consume",
        payload: {
          installationId,
          deviceName: "Restored Ada iPhone",
          qrToken: sameInstallationPairing.json().qrToken
        }
      });
      assert.equal(blockedSameInstallation.statusCode, 409);
      assert.equal(
        blockedSameInstallation.json().error.code,
        "active_session_exists"
      );
      const originalStillActive = await childRequest(credential, {
        url: "/v1/child/snapshot"
      });
      assert.equal(originalStillActive.statusCode, 200);

      const replacementPairing = await parentRequest(firstParent.token, {
        method: "POST",
        url: `/v1/parent/children/${childProfileId}/pairing-sessions`,
        payload: {}
      });
      assert.equal(replacementPairing.statusCode, 201);
      const replacementInstallationId = randomUUID();
      const replacementPaired = await server.inject({
        method: "POST",
        url: "/v1/pairing/consume",
        payload: {
          installationId: replacementInstallationId,
          deviceName: "Ada replacement iPhone",
          appVersion: "1.0.0",
          appBuild: "1",
          qrToken: replacementPairing.json().qrToken
        }
      });
      assert.equal(replacementPaired.statusCode, 200);
      const replacementPolicy = await recordAppliedSetupPolicy(
        replacementInstallationId
      );
      const originalDevice = await prisma.device.findUniqueOrThrow({
        where: { installationId }
      });
      await prisma.policyApplicationAck.create({
        data: {
          childProfileId,
          policyVersion: replacementPolicy.version,
          deviceId: originalDevice.id,
          result: "applied",
          appliedAt: new Date(now),
          reportedAt: new Date(now)
        }
      });
      const replacementCredential =
        replacementPaired.json().deviceCredential as string;
      const blockedReplacement = await childRequest(replacementCredential, {
        method: "POST",
        url: "/v1/child/setup/complete",
        payload: {
          authorizationStatus: "approved",
          earnedTimeAppCount: 1,
          shieldStatus: "locked"
        }
      });
      assert.equal(blockedReplacement.statusCode, 409);
      assert.equal(
        blockedReplacement.json().error.code,
        "active_session_exists"
      );
      now += 900_000;

      const recoveryStartId = randomUUID();
      const recoveryStart = await childRequest(credential, {
        method: "POST",
        url: `/v1/child/earned-time-sessions/${recoveryStartId}/start`,
        payload: {
          requestedDurationSeconds: 900,
          balanceBeforeSeconds: 901
        }
      });
      assert.equal(recoveryStart.statusCode, 422, recoveryStart.body);
      assert.equal(recoveryStart.json().error.code, "insufficient_balance");
      assert.equal(
        (
          await prisma.earnedTimeSession.findFirstOrThrow({
            where: { localSessionId: orphanedSessionId }
          })
        ).state,
        "settled"
      );

      const lateOrphanedFinal = await childRequest(credential, {
        method: "PUT",
        url: `/v1/child/earned-time-sessions/${orphanedSessionId}`,
        payload: settlementFromStart(orphanedStart.json(), {
          endReason: "expired",
          endedAt: orphanedStart.json().expiresAt,
          consumedSeconds: 900
        })
      });
      assert.equal(lateOrphanedFinal.statusCode, 200);
      assert.equal(lateOrphanedFinal.json().consumedSeconds, 900);
      assert.equal(lateOrphanedFinal.json().balanceSeconds, 1);

      const recoveryGrant = await parentRequest(firstParent.token, {
        method: "POST",
        url: `/v1/parent/children/${childProfileId}/credit-grants`,
        payload: {
          seconds: 899,
          reason: "Recovery session",
          idempotencyKey: randomUUID()
        }
      });
      assert.equal(recoveryGrant.statusCode, 200);
      const replacementStart = await childRequest(credential, {
        method: "POST",
        url: `/v1/child/earned-time-sessions/${recoveryStartId}/start`,
        payload: {
          requestedDurationSeconds: 900,
          balanceBeforeSeconds: 900
        }
      });
      assert.equal(replacementStart.statusCode, 200);
      const replacementCancel = await childRequest(credential, {
        method: "PUT",
        url: `/v1/child/earned-time-sessions/${recoveryStartId}`,
        payload: settlementFromStart(replacementStart.json(), {
          endedAt: replacementStart.json().startedAt,
          consumedSeconds: 0
        })
      });
      assert.equal(replacementCancel.statusCode, 200);
      assert.equal(replacementCancel.json().consumedSeconds, 0);

      const failedActivationSessionId = randomUUID();
      const failedActivationStart = await childRequest(credential, {
        method: "POST",
        url: `/v1/child/earned-time-sessions/${failedActivationSessionId}/start`,
        payload: {
          requestedDurationSeconds: 900,
          balanceBeforeSeconds: 900
        }
      });
      assert.equal(failedActivationStart.statusCode, 200);
      now += 300_000;
      const failedActivation = await childRequest(credential, {
        method: "POST",
        url: `/v1/child/earned-time-sessions/${failedActivationSessionId}/activate`,
        payload: {}
      });
      assert.equal(failedActivation.statusCode, 200);
      now += 100;
      const failedActivationFinal = await childRequest(credential, {
        method: "PUT",
        url: `/v1/child/earned-time-sessions/${failedActivationSessionId}`,
        payload: settlementFromStart(failedActivationStart.json(), {
          endReason: "activation_failed",
          endedAt: failedActivationStart.json().startedAt,
          consumedSeconds: 0
        })
      });
      assert.equal(
        failedActivationFinal.statusCode,
        200,
        failedActivationFinal.body
      );
      assert.equal(failedActivationFinal.json().consumedSeconds, 1);
      assert.equal(failedActivationFinal.json().balanceSeconds, 899);

      const completedReplacement = await childRequest(replacementCredential, {
        method: "POST",
        url: "/v1/child/setup/complete",
        payload: {
          authorizationStatus: "approved",
          earnedTimeAppCount: 1,
          shieldStatus: "locked"
        }
      });
      assert.equal(completedReplacement.statusCode, 200);
      assert.equal(
        await prisma.managedApp.count({
          where: { sourceDeviceId: originalDevice.id, archivedAt: null }
        }),
        0
      );
      assert.equal(
        await prisma.managedApp.count({
          where: {
            childProfileId,
            sourceDeviceId: { not: originalDevice.id },
            archivedAt: null
          }
        }),
        1
      );
      const retiredSnapshot = await childRequest(credential, {
        url: "/v1/child/snapshot"
      });
      assert.equal(retiredSnapshot.statusCode, 401);

      const snapshot = await childRequest(replacementCredential, {
        url: "/v1/child/snapshot"
      });
      assert.equal(snapshot.json().balanceSeconds, 899);
      assert.equal(snapshot.json().ledgerRevision, 8);
      assert.equal(await prisma.creditLedgerEntry.count(), 8);
      assert.equal(await prisma.earnedTimeSession.count(), 7);
      const sessionEndedEvent = await prisma.pushOutboxEvent.findFirstOrThrow({
        where: {
          eventType: "earned_time_session_ended",
          childProfileId
        },
        orderBy: [{ createdAt: "asc" }, { id: "asc" }]
      });
      assert.equal(sessionEndedEvent.childProfileId, childProfileId);
      assert.equal(
        (sessionEndedEvent.payload as { childName?: string }).childName,
        "Ada"
      );

      await prisma.childProfile.update({
        where: { id: childProfileId },
        data: { status: "archived", archivedAt: new Date() }
      });
      const archivedGrant = await parentRequest(firstParent.token, {
        method: "POST",
        url: `/v1/parent/children/${childProfileId}/credit-grants`,
        payload: {
          seconds: 300,
          reason: "Archived profiles are read-only",
          idempotencyKey: randomUUID()
        }
      });
      assert.equal(archivedGrant.statusCode, 404);
      assert.equal(await prisma.creditLedgerEntry.count(), 8);

      const ledger = await prisma.creditLedgerEntry.findFirstOrThrow();
      await assert.rejects(
        () => prisma.creditLedgerEntry.update({
          where: { id: ledger.id },
          data: { reason: "mutated" }
        }),
        /append-only/
      );
    } finally {
      await server.close();
      await prisma.$disconnect();
      await legacyStore.close();
    }
  }
);

function settlement(overrides: Record<string, unknown> = {}) {
  return {
    localSessionId: randomUUID(),
    requestedDurationSeconds: 900,
    balanceBeforeSeconds: 1_800,
    startedAt: "2026-07-27T12:00:00.000Z",
    expiresAt: "2026-07-27T12:15:00.000Z",
    endedAt: "2026-07-27T12:05:00.000Z",
    consumedSeconds: 300,
    endReason: "manual_stop",
    idempotencyKey: randomUUID(),
    ...overrides
  };
}

function settlementFromStart(
  start: {
    localSessionId: string;
    requestedDurationSeconds: number;
    balanceBeforeSeconds: number;
    startedAt: string;
    expiresAt: string;
  },
  overrides: Record<string, unknown> = {}
) {
  return settlement({
    localSessionId: start.localSessionId,
    requestedDurationSeconds: start.requestedDurationSeconds,
    balanceBeforeSeconds: start.balanceBeforeSeconds,
    startedAt: start.startedAt,
    expiresAt: start.expiresAt,
    ...overrides
  });
}
