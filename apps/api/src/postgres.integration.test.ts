import assert from "node:assert/strict";
import test from "node:test";

import postgres from "postgres";

import type { EarnedTimeSettlement } from "../../../libs/shared/src/index.js";
import { ApiError } from "./domain.js";
import { PostgresPagePassStore } from "./postgres-store.js";

const databaseUrl = process.env.TEST_DATABASE_URL;
const parentToken = "postgres-test-parent-token";
const pepper = "postgres-test-server-pepper";
const now = Date.parse("2026-07-17T12:00:00.000Z");

function settlement(
  overrides: Partial<EarnedTimeSettlement> = {}
): EarnedTimeSettlement {
  return {
    localSessionId: "persisted-session",
    requestedDurationSeconds: 900,
    balanceBeforeSeconds: 1_800,
    startedAt: "2026-07-17T12:00:00.000Z",
    expiresAt: "2026-07-17T12:15:00.000Z",
    endedAt: "2026-07-17T12:01:00.000Z",
    consumedSeconds: 59,
    endReason: "manual_stop",
    idempotencyKey: "persisted-settlement",
    ...overrides
  };
}

async function resetDatabase(url: string): Promise<void> {
  const sql = postgres(url, { max: 1 });
  try {
    await sql.unsafe(`
      TRUNCATE TABLE
        pairing_rate_attempts,
        earned_time_spends,
        credit_grants,
        active_devices,
        pairing_sessions,
        children,
        server_state
      CASCADE
    `);
  } finally {
    await sql.end();
  }
}

async function expectApiError(
  action: () => Promise<unknown>,
  status: number,
  code: string
): Promise<void> {
  await assert.rejects(action, (error: unknown) => {
    assert.ok(error instanceof ApiError);
    assert.equal(error.status, status);
    assert.equal(error.code, code);
    return true;
  });
}

test(
  "PostgreSQL state and constraints survive a store restart",
  { skip: databaseUrl === undefined ? "TEST_DATABASE_URL is not set" : false },
  async () => {
    assert.ok(databaseUrl !== undefined);
    await resetDatabase(databaseUrl);

    const first = await PostgresPagePassStore.create({
      databaseUrl,
      parentToken,
      pepper,
      now: () => now
    });
    const ada = await first.createChild("Ada");
    const grace = await first.createChild("Grace");
    const pairing = await first.createPairingSession(ada.id);
    const paired = await first.consumePairing(
      {
        installationId: "persisted-installation",
        deviceName: "Ada Phone",
        qrToken: pairing.qrToken
      },
      { remoteAddress: "192.0.2.1" }
    );
    const grantInput = {
      seconds: 1_800,
      reason: "Persisted reading credit",
      idempotencyKey: "persisted-grant"
    };
    const grant = await first.grantCredit(ada.id, grantInput);
    const settlementInput = settlement();
    const spend = await first.settleEarnedTime(
      paired.deviceCredential,
      settlementInput.localSessionId,
      settlementInput
    );
    assert.equal(spend.consumedSeconds, 60);

    for (let attempt = 0; attempt < 5; attempt += 1) {
      await expectApiError(
        () => first.consumePairing(
          {
            installationId: "persisted-rate-installation",
            deviceName: "Rate Test Phone",
            numericCode: pairing.numericCode
          },
          { remoteAddress: `198.51.100.${attempt + 1}` }
        ),
        409,
        "pairing_session_consumed"
      );
    }

    const beforeRestart = await first.snapshot(paired.deviceCredential);
    await first.close();

    const second = await PostgresPagePassStore.create({
      databaseUrl,
      parentToken,
      pepper,
      now: () => now
    });
    try {
      assert.doesNotThrow(() => second.authenticateParent(parentToken));
      const afterRestart = await second.snapshot(paired.deviceCredential);
      assert.equal(afterRestart.serverInstanceId, beforeRestart.serverInstanceId);
      assert.equal(afterRestart.balanceSeconds, 1_740);
      assert.equal(afterRestart.ledgerRevision, 2);
      assert.equal((await second.listChildren()).length, 2);

      assert.deepEqual(await second.grantCredit(ada.id, grantInput), grant);
      assert.deepEqual(
        await second.settleEarnedTime(
          paired.deviceCredential,
          settlementInput.localSessionId,
          settlementInput
        ),
        spend
      );
      assert.equal(
        (await second.snapshot(paired.deviceCredential)).ledgerRevision,
        2
      );

      await expectApiError(
        () => second.consumePairing(
          {
            installationId: "persisted-installation",
            deviceName: "Ada Phone",
            qrToken: pairing.qrToken
          },
          { remoteAddress: "192.0.2.2" }
        ),
        409,
        "pairing_session_consumed"
      );
      await expectApiError(
        () => second.consumePairing(
          {
            installationId: "persisted-rate-installation",
            deviceName: "Rate Test Phone",
            numericCode: pairing.numericCode
          },
          { remoteAddress: "198.51.100.99" }
        ),
        429,
        "pairing_rate_limited"
      );

      const gracePairing = await second.createPairingSession(grace.id);
      await expectApiError(
        () => second.consumePairing(
          {
            installationId: "persisted-installation",
            deviceName: "Ada Phone",
            qrToken: gracePairing.qrToken
          },
          { remoteAddress: "192.0.2.3" }
        ),
        409,
        "installation_already_bound"
      );

      const adaPairing = await second.createPairingSession(ada.id);
      await expectApiError(
        () => second.consumePairing(
          {
            installationId: "different-installation",
            deviceName: "Other Phone",
            qrToken: adaPairing.qrToken
          },
          { remoteAddress: "192.0.2.4" }
        ),
        409,
        "active_device_exists"
      );
    } finally {
      await second.close();
      await resetDatabase(databaseUrl);
    }
  }
);

test(
  "concurrent settlements serialize balance updates and idempotent retries",
  { skip: databaseUrl === undefined ? "TEST_DATABASE_URL is not set" : false },
  async () => {
    assert.ok(databaseUrl !== undefined);
    await resetDatabase(databaseUrl);

    const store = await PostgresPagePassStore.create({
      databaseUrl,
      parentToken,
      pepper,
      now: () => now
    });
    try {
      const child = await store.createChild("Concurrent child");
      const pairing = await store.createPairingSession(child.id);
      const paired = await store.consumePairing(
        {
          installationId: "concurrent-installation",
          deviceName: "Concurrent Phone",
          qrToken: pairing.qrToken
        },
        { remoteAddress: "192.0.2.40" }
      );
      await store.grantCredit(child.id, {
        seconds: 120,
        reason: "Concurrency test credit",
        idempotencyKey: "concurrent-grant"
      });

      const retryInput = settlement({
        localSessionId: "retry-session",
        requestedDurationSeconds: 60,
        balanceBeforeSeconds: 120,
        expiresAt: "2026-07-17T12:01:00.000Z",
        endedAt: "2026-07-17T12:01:00.000Z",
        consumedSeconds: 60,
        endReason: "expired",
        idempotencyKey: "retry-settlement"
      });
      const retryResults = await Promise.all([
        store.settleEarnedTime(
          paired.deviceCredential,
          retryInput.localSessionId,
          retryInput
        ),
        store.settleEarnedTime(
          paired.deviceCredential,
          retryInput.localSessionId,
          retryInput
        )
      ]);
      assert.deepEqual(retryResults[0], retryResults[1]);
      assert.equal((await store.snapshot(paired.deviceCredential)).balanceSeconds, 60);

      const competingInputs = [
        settlement({
          localSessionId: "competing-session-a",
          requestedDurationSeconds: 60,
          balanceBeforeSeconds: 60,
          expiresAt: "2026-07-17T12:01:00.000Z",
          endedAt: "2026-07-17T12:01:00.000Z",
          consumedSeconds: 60,
          endReason: "expired",
          idempotencyKey: "competing-settlement-a"
        }),
        settlement({
          localSessionId: "competing-session-b",
          requestedDurationSeconds: 60,
          balanceBeforeSeconds: 60,
          expiresAt: "2026-07-17T12:01:00.000Z",
          endedAt: "2026-07-17T12:01:00.000Z",
          consumedSeconds: 60,
          endReason: "expired",
          idempotencyKey: "competing-settlement-b"
        })
      ];
      const competingResults = await Promise.allSettled(
        competingInputs.map((input) => store.settleEarnedTime(
          paired.deviceCredential,
          input.localSessionId,
          input
        ))
      );
      assert.equal(
        competingResults.filter((result) => result.status === "fulfilled").length,
        1
      );
      const rejected = competingResults.find(
        (result): result is PromiseRejectedResult => result.status === "rejected"
      );
      assert.ok(rejected?.reason instanceof ApiError);
      assert.equal(rejected.reason.code, "insufficient_balance");

      const snapshot = await store.snapshot(paired.deviceCredential);
      assert.equal(snapshot.balanceSeconds, 0);
      assert.equal(snapshot.ledgerRevision, 3);
    } finally {
      await store.close();
      await resetDatabase(databaseUrl);
    }
  }
);
