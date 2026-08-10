import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import test from "node:test";

import {
  createBetterAuth,
  createBetterAuthFastifyHandler
} from "./auth/better-auth.js";
import type { ApiEnv } from "./config/env.js";
import { createPrismaClient } from "./db/prisma.js";
import { ApiError } from "./domain.js";
import { PrismaFamilyService } from "./family/family-service.js";
import { createBetterAuthParentApi } from "./family/parent-api.js";
import { createFastifyServer } from "./fastify-server.js";
import { PrismaPairingService } from "./pairing/pairing-service.js";
import { PostgresPagePassStore } from "./postgres-store.js";

const databaseUrl = process.env.TEST_DATABASE_URL;

test(
  "legacy family claim migrates credit and device state exactly once",
  { skip: databaseUrl === undefined ? "TEST_DATABASE_URL is not set" : false },
  async () => {
    assert.ok(databaseUrl !== undefined);
    const prisma = createPrismaClient(databaseUrl);
    const database = await prisma.$queryRaw<Array<{ name: string }>>`
      SELECT current_database() AS name
    `;
    assert.match(database[0]?.name ?? "", /_test$/);
    await prisma.$executeRawUnsafe(`
      TRUNCATE TABLE families, users, parent_accounts, server_state CASCADE
    `);
    await prisma.parentAccount.create({
      data: {
        id: "00000000-0000-4000-8000-000000000001",
        issuer: "pagepass:local",
        subject: "default",
        displayName: "Local Parent",
        createdAt: new Date("2026-08-06T12:00:00.000Z")
      }
    });

    const pepper = "legacy-family-claim-integration-pepper";
    const legacyParentToken = "legacy-family-claim-parent-token";
    let now = Date.parse("2026-08-06T12:00:00.000Z");
    const legacy = await PostgresPagePassStore.create({
      databaseUrl,
      parentToken: legacyParentToken,
      pepper,
      now: () => now
    });
    const legacyChild = await legacy.createChild("Legacy Child");
    const pairingSession = await legacy.createPairingSession(legacyChild.id);
    const legacyInstallationId = `legacy-installation-${randomUUID()}`;
    const paired = await legacy.consumePairing(
      {
        installationId: legacyInstallationId,
        deviceName: "Legacy Child iPhone",
        qrToken: pairingSession.qrToken
      },
      { remoteAddress: "192.0.2.10" }
    );
    await legacy.grantCredit(legacyChild.id, {
      seconds: 1_200,
      reason: "Legacy reading reward",
      idempotencyKey: "legacy-grant-one"
    });
    now += 60_000;
    await legacy.settleEarnedTime(
      paired.deviceCredential,
      "legacy-session-one",
      {
        localSessionId: "legacy-session-one",
        requestedDurationSeconds: 600,
        balanceBeforeSeconds: 1_200,
        startedAt: "2026-08-06T12:00:00.000Z",
        expiresAt: "2026-08-06T12:10:00.000Z",
        endedAt: "2026-08-06T12:05:00.000Z",
        consumedSeconds: 300,
        endReason: "manual_stop",
        idempotencyKey: "legacy-spend-one"
      }
    );
    now += 60_000;
    await legacy.grantCredit(legacyChild.id, {
      seconds: 600,
      reason: "Legacy bonus",
      idempotencyKey: "legacy-grant-two"
    });
    const emptyLegacyChild = await legacy.createChild("No Device Child");
    const openPairing = await legacy.createPairingSession(emptyLegacyChild.id);

    const env: ApiEnv = {
      nodeEnv: "test",
      authMode: "local",
      databaseUrl,
      betterAuthSecret: "legacy-family-claim-secret-at-least-32",
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
    const families = new PrismaFamilyService(prisma, {
      legacyMigrationPepper: pepper,
      now: () => now
    });
    const pairing = new PrismaPairingService(prisma, {
      pepper,
      now: () => now,
      legacy
    });
    const parentBearer = "better-auth-development-parent";
    const parentApi = createBetterAuthParentApi({
      auth,
      families,
      pairing,
      localDevelopmentParent: {
        token: parentBearer,
        id: "better-auth-parent-one",
        name: "Parent One",
        email: "parent-one@example.com"
      }
    });
    const server = createFastifyServer({
      trustedOrigins: env.trustedOrigins,
      authHandler: createBetterAuthFastifyHandler(auth),
      parentApi,
      pairingApi: pairing,
      logger: false,
      legacyHandler: async (_request, response) => {
        response.writeHead(500);
        response.end();
      }
    });
    const claim = (localParentToken: string) => server.inject({
      method: "POST",
      url: "/v1/parent/claim-local-data",
      headers: { authorization: `Bearer ${parentBearer}` },
      payload: { localParentToken }
    });

    try {
      const invalidProof = await claim("wrong-token");
      assert.equal(invalidProof.statusCode, 401);
      assert.equal(invalidProof.json().error.code, "invalid_local_parent_token");
      assert.equal(await prisma.family.count(), 0);

      const imported = await claim(legacyParentToken);
      assert.equal(imported.statusCode, 200);
      assert.deepEqual(imported.json(), { claimedChildren: 2 });
      assert.equal(await prisma.childProfile.count(), 2);
      assert.equal(await prisma.family.count(), 1);

      const balance = await prisma.childCreditBalance.findUniqueOrThrow({
        where: { childProfileId: legacyChild.id }
      });
      assert.equal(balance.balanceSeconds, 1_500n);
      assert.equal(balance.ledgerRevision, 3n);
      const ledger = await prisma.creditLedgerEntry.findMany({
        where: { childProfileId: legacyChild.id },
        orderBy: { ledgerRevision: "asc" }
      });
      assert.deepEqual(
        ledger.map((entry) => ({
          revision: entry.ledgerRevision,
          amount: entry.amountSeconds,
          balance: entry.balanceAfterSeconds,
          type: entry.entryType
        })),
        [
          { revision: 1n, amount: 1_200n, balance: 1_200n, type: "parent_grant" },
          { revision: 2n, amount: -300n, balance: 900n, type: "session_spend" },
          { revision: 3n, amount: 600n, balance: 1_500n, type: "parent_grant" }
        ]
      );

      const migratedDevice = await prisma.device.findUniqueOrThrow({
        where: { installationId: legacyInstallationId }
      });
      assert.equal(migratedDevice.status, "pending_setup");
      assert.equal(migratedDevice.appVersion, "legacy");
      const snapshot = await server.inject({
        method: "GET",
        url: "/v1/child/snapshot",
        headers: { authorization: `Bearer ${paired.deviceCredential}` }
      });
      assert.equal(snapshot.statusCode, 200);
      assert.equal(snapshot.json().childProfileId, legacyChild.id);
      assert.equal(snapshot.json().balanceSeconds, 1_500);
      assert.equal(snapshot.json().deviceStatus, "pending_setup");

      const consumedPairing = await prisma.legacyPairingSession.findUniqueOrThrow({
        where: { id: openPairing.id }
      });
      assert.ok(consumedPairing.consumedAt !== null);

      const retry = await claim(legacyParentToken);
      assert.deepEqual(retry.json(), { claimedChildren: 2 });
      assert.equal(await prisma.childProfile.count(), 2);
      assert.equal(await prisma.creditLedgerEntry.count(), 3);

      await families.ensureParentUser(
        { id: "better-auth-parent-two", name: "Parent Two" },
        "parent-two@example.com"
      );
      await assert.rejects(
        () => families.claimLegacyData(
          { id: "better-auth-parent-two", name: "Parent Two" },
          { localParentToken: legacyParentToken }
        ),
        (error: unknown) => {
          assert.ok(error instanceof ApiError);
          assert.equal(error.status, 409);
          assert.equal(error.code, "local_data_already_claimed");
          return true;
        }
      );
      assert.equal(await prisma.family.count(), 1);

      await assert.rejects(
        () => legacy.grantCredit(legacyChild.id, {
          seconds: 300,
          reason: "Late legacy write",
          idempotencyKey: "late-legacy-write"
        }),
        (error: unknown) => {
          assert.ok(error instanceof ApiError);
          assert.equal(error.code, "local_data_already_claimed");
          return true;
        }
      );
    } finally {
      await server.close();
      await legacy.close();
      await prisma.$disconnect();
    }
  }
);
