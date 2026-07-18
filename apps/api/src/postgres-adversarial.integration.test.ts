import assert from "node:assert/strict";
import test from "node:test";

import postgres from "postgres";

import {
  appleIdentityIssuer,
  type AppleIdentityTokenVerifier,
  type VerifiedAppleIdentity
} from "./apple-token-verifier.js";
import { ApiError } from "./domain.js";
import { createPagePassHttpServer } from "./main.js";
import { PostgresPagePassStore } from "./postgres-store.js";

const databaseUrl = process.env.TEST_DATABASE_URL;
const parentToken = "adversarial-local-parent";
const pepper = "adversarial-stable-pepper";
const initialNow = Date.parse("2026-07-17T12:00:00.000Z");
const localParentId = "00000000-0000-4000-8000-000000000001";

class FakeAppleVerifier implements AppleIdentityTokenVerifier {
  private readonly identities = new Map<string, VerifiedAppleIdentity>();

  set(token: string, subject: string, nonce: string): void {
    this.identities.set(token, {
      issuer: appleIdentityIssuer,
      subject,
      nonce
    });
  }

  async verify(identityToken: string): Promise<VerifiedAppleIdentity> {
    const identity = this.identities.get(identityToken);
    if (identity === undefined) throw new Error("Unknown fake identity token");
    return identity;
  }
}

async function resetDatabase(url: string): Promise<void> {
  const sql = postgres(url, { max: 1 });
  try {
    await sql.unsafe(`
      TRUNCATE TABLE
        parent_sessions,
        apple_auth_challenges,
        pairing_rate_attempts,
        earned_time_spends,
        credit_grants,
        active_devices,
        pairing_sessions,
        children,
        server_state
      CASCADE
    `);
    await sql`
      DELETE FROM parent_accounts
      WHERE id <> ${localParentId}
    `;
  } finally {
    await sql.end();
  }
}

async function startTestServer(store: PostgresPagePassStore): Promise<{
  baseUrl: string;
  close: () => Promise<void>;
}> {
  const server = createPagePassHttpServer(store);
  await new Promise<void>((resolve, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", resolve);
  });
  const address = server.address();
  assert.ok(address !== null && typeof address !== "string");
  return {
    baseUrl: `http://127.0.0.1:${address.port}`,
    close: () => new Promise<void>((resolve, reject) => {
      server.close((error) => error === undefined ? resolve() : reject(error));
    })
  };
}

async function responseJson(response: Response): Promise<unknown> {
  const text = await response.text();
  return text.length === 0 ? undefined : JSON.parse(text);
}

async function appleIdentity(
  store: PostgresPagePassStore,
  verifier: FakeAppleVerifier,
  subject: string,
  identityToken: string
) {
  const challenge = await store.createAppleAuthChallenge({
    remoteAddress: `identity-${subject}`
  });
  verifier.set(identityToken, subject, challenge.nonce);
  const session = await store.createAppleSession({
    challengeId: challenge.challengeId,
    state: challenge.challengeId,
    identityToken,
    displayName: subject
  });
  return {
    session,
    identity: await store.authenticateParent(session.sessionToken)
  };
}

test(
  "PostgreSQL adversarial hardening",
  { skip: databaseUrl === undefined ? "TEST_DATABASE_URL is not set" : false },
  async (context) => {
    assert.ok(databaseUrl !== undefined);

    await context.test("pepper check is persistent and mode independent", async () => {
      await resetDatabase(databaseUrl);
      const localStore = await PostgresPagePassStore.create({
        databaseUrl,
        parentToken,
        pepper,
        authMode: "local"
      });
      await localStore.close();

      const verifier = new FakeAppleVerifier();
      const appleStore = await PostgresPagePassStore.create({
        databaseUrl,
        pepper,
        authMode: "apple",
        appleTokenVerifier: verifier
      });
      await appleStore.close();

      await assert.rejects(
        () => PostgresPagePassStore.create({
          databaseUrl,
          pepper: "wrong-pepper",
          authMode: "apple",
          appleTokenVerifier: verifier
        }),
        /PAGEPASS_SERVER_PEPPER does not match/
      );

      const sql = postgres(databaseUrl, { max: 1 });
      try {
        const stateRows = await sql<{ pepper_bytes: number }[]>`
          SELECT octet_length(pepper_check)::int AS pepper_bytes
          FROM server_state
          WHERE singleton = true
        `;
        assert.equal(stateRows[0]?.pepper_bytes, 32);
        const migrationRows = await sql<{ migration_name: string }[]>`
          SELECT migration_name
          FROM _prisma_migrations
          WHERE finished_at IS NOT NULL
            AND rolled_back_at IS NULL
          ORDER BY migration_name
        `;
        assert.deepEqual(
          migrationRows.map((row) => row.migration_name),
          [
            "20260717120000_initial_schema",
            "20260717121000_parent_auth",
            "20260717122000_adversarial_hardening",
            "20260717123000_local_data_claim_state",
            "20260717124000_prisma_identity"
          ]
        );
      } finally {
        await sql.end();
      }
    });

    await context.test("pre-003 pepper upgrade requires persisted-token proof", async () => {
      await resetDatabase(databaseUrl);
      const localStore = await PostgresPagePassStore.create({
        databaseUrl,
        parentToken,
        pepper,
        authMode: "local"
      });
      await localStore.close();

      const sql = postgres(databaseUrl, { max: 1 });
      const verifier = new FakeAppleVerifier();
      try {
        await sql`UPDATE server_state SET pepper_check = NULL WHERE singleton = true`;
        await assert.rejects(
          () => PostgresPagePassStore.create({
            databaseUrl,
            parentToken,
            pepper: "wrong-upgrade-pepper",
            authMode: "local"
          }),
          /must match with PAGEPASS_SERVER_PEPPER/
        );
        const afterWrongPepper = await sql<{ pepper_check: Uint8Array | null }[]>`
          SELECT pepper_check FROM server_state WHERE singleton = true
        `;
        assert.equal(afterWrongPepper[0]?.pepper_check, null);

        await assert.rejects(
          () => PostgresPagePassStore.create({
            databaseUrl,
            pepper,
            authMode: "apple",
            appleTokenVerifier: verifier
          }),
          /PAGEPASS_PARENT_TOKEN is required/
        );
        const afterMissingProof = await sql<{ pepper_check: Uint8Array | null }[]>`
          SELECT pepper_check FROM server_state WHERE singleton = true
        `;
        assert.equal(afterMissingProof[0]?.pepper_check, null);

        const upgraded = await PostgresPagePassStore.create({
          databaseUrl,
          parentToken,
          pepper,
          authMode: "apple",
          appleTokenVerifier: verifier
        });
        await upgraded.close();
        const verified = await sql<{ pepper_bytes: number }[]>`
          SELECT octet_length(pepper_check)::int AS pepper_bytes
          FROM server_state
          WHERE singleton = true
        `;
        assert.equal(verified[0]?.pepper_bytes, 32);
      } finally {
        await sql.end();
      }

      await resetDatabase(databaseUrl);
      const appleOnly = await PostgresPagePassStore.create({
        databaseUrl,
        pepper,
        authMode: "apple",
        appleTokenVerifier: verifier
      });
      await appleOnly.close();
      const legacySql = postgres(databaseUrl, { max: 1 });
      try {
        await legacySql`UPDATE server_state SET pepper_check = NULL WHERE singleton = true`;
      } finally {
        await legacySql.end();
      }
      const reopenedAppleOnly = await PostgresPagePassStore.create({
        databaseUrl,
        pepper,
        authMode: "apple",
        appleTokenVerifier: verifier
      });
      await reopenedAppleOnly.close();
    });

    await context.test("Apple challenge rate limit persists and cleans old rows", async () => {
      await resetDatabase(databaseUrl);
      let now = initialNow;
      const store = await PostgresPagePassStore.create({
        databaseUrl,
        pepper,
        authMode: "apple",
        appleTokenVerifier: new FakeAppleVerifier(),
        now: () => now
      });
      const server = await startTestServer(store);
      try {
        for (let attempt = 0; attempt < 10; attempt += 1) {
          const response = await fetch(`${server.baseUrl}/v1/auth/apple/challenges`, {
            method: "POST",
            headers: { "content-type": "application/json" },
            body: "{}"
          });
          assert.equal(response.status, 201);
        }
        const limited = await fetch(`${server.baseUrl}/v1/auth/apple/challenges`, {
          method: "POST",
          headers: { "content-type": "application/json" },
          body: "{}"
        });
        assert.equal(limited.status, 429);
        assert.equal(
          (await responseJson(limited) as { error: { code: string } }).error.code,
          "apple_challenge_rate_limited"
        );

        now += 5 * 60 * 1_000;
        const afterWindow = await fetch(
          `${server.baseUrl}/v1/auth/apple/challenges`,
          { method: "POST", headers: { "content-type": "application/json" }, body: "{}" }
        );
        assert.equal(afterWindow.status, 201);

        const sql = postgres(databaseUrl, { max: 1 });
        try {
          const challengeCounts = await sql<{ count: number }[]>`
            SELECT COUNT(*)::int AS count FROM apple_auth_challenges
          `;
          const attemptCounts = await sql<{ count: number }[]>`
            SELECT COUNT(*)::int AS count
            FROM pairing_rate_attempts
            WHERE dimension = 'apple_address'
          `;
          assert.equal(challengeCounts[0]?.count, 1);
          assert.equal(attemptCounts[0]?.count, 1);
        } finally {
          await sql.end();
        }
      } finally {
        await server.close();
        await store.close();
      }
    });

    await context.test("Apple parent can claim legacy local children once", async () => {
      await resetDatabase(databaseUrl);
      const localStore = await PostgresPagePassStore.create({
        databaseUrl,
        parentToken,
        pepper,
        authMode: "local"
      });
      await localStore.createChild("Legacy Ada");
      await localStore.createChild("Legacy Grace");
      await localStore.close();

      const verifier = new FakeAppleVerifier();
      const hybridStore = await PostgresPagePassStore.create({
        databaseUrl,
        parentToken,
        pepper,
        authMode: "hybrid",
        appleTokenVerifier: verifier
      });
      const localIdentity = await hybridStore.authenticateParent(parentToken);
      await assert.rejects(
        () => hybridStore.claimLocalData(localIdentity, { localParentToken: parentToken }),
        (error: unknown) => {
          assert.ok(error instanceof ApiError);
          assert.equal(error.code, "apple_parent_required");
          return true;
        }
      );

      const firstApple = await appleIdentity(
        hybridStore,
        verifier,
        "upgrade-parent",
        "upgrade-token"
      );
      const secondApple = await appleIdentity(
        hybridStore,
        verifier,
        "other-parent",
        "other-token"
      );
      const server = await startTestServer(hybridStore);
      try {
        const wrongProof = await fetch(`${server.baseUrl}/v1/parent/claim-local-data`, {
          method: "POST",
          headers: {
            authorization: `Bearer ${firstApple.session.sessionToken}`,
            "content-type": "application/json"
          },
          body: JSON.stringify({ localParentToken: "wrong-local-token" })
        });
        assert.equal(wrongProof.status, 401);

        const claim = await fetch(`${server.baseUrl}/v1/parent/claim-local-data`, {
          method: "POST",
          headers: {
            authorization: `Bearer ${firstApple.session.sessionToken}`,
            "content-type": "application/json"
          },
          body: JSON.stringify({ localParentToken: parentToken })
        });
        assert.equal(claim.status, 200);
        assert.deepEqual(await responseJson(claim), { claimedChildren: 2 });

        assert.deepEqual(
          await hybridStore.claimLocalData(firstApple.identity, {
            localParentToken: parentToken
          }),
          { claimedChildren: 2 }
        );
        await assert.rejects(
          () => hybridStore.claimLocalData(secondApple.identity, {
            localParentToken: parentToken
          }),
          (error: unknown) => {
            assert.ok(error instanceof ApiError);
            assert.equal(error.code, "local_data_already_claimed");
            return true;
          }
        );
        assert.equal((await hybridStore.listChildren(firstApple.identity)).length, 2);
        assert.equal((await hybridStore.listChildren(secondApple.identity)).length, 0);
        assert.equal((await hybridStore.listChildren(localIdentity)).length, 0);
      } finally {
        await server.close();
        await hybridStore.close();
      }
    });

    await context.test("legacy claim is atomic with local writes and pairing", async () => {
      await resetDatabase(databaseUrl);
      const verifier = new FakeAppleVerifier();
      const store = await PostgresPagePassStore.create({
        databaseUrl,
        parentToken,
        pepper,
        authMode: "hybrid",
        appleTokenVerifier: verifier
      });
      try {
        const localIdentity = await store.authenticateParent(parentToken);
        const legacyChild = await store.createChild("Legacy Child", localIdentity);
        const outstandingPairing = await store.createPairingSession(
          legacyChild.id,
          localIdentity
        );
        const firstApple = await appleIdentity(
          store,
          verifier,
          "atomic-upgrade-parent",
          "atomic-upgrade-token"
        );
        const secondApple = await appleIdentity(
          store,
          verifier,
          "atomic-other-parent",
          "atomic-other-token"
        );

        const [claimResult, createResult] = await Promise.allSettled([
          store.claimLocalData(firstApple.identity, { localParentToken: parentToken }),
          store.createChild("Concurrent Local Child", localIdentity)
        ]);
        assert.equal(claimResult.status, "fulfilled");
        if (createResult.status === "rejected") {
          assert.ok(createResult.reason instanceof ApiError);
          assert.equal(createResult.reason.code, "local_data_already_claimed");
        }

        const claimedChildren = await store.listChildren(firstApple.identity);
        assert.equal(claimedChildren.length, claimResult.value.claimedChildren);
        assert.equal((await store.listChildren(localIdentity)).length, 0);
        assert.deepEqual(
          await store.claimLocalData(firstApple.identity, {
            localParentToken: parentToken
          }),
          claimResult.value
        );
        await assert.rejects(
          () => store.claimLocalData(secondApple.identity, {
            localParentToken: parentToken
          }),
          (error: unknown) => {
            assert.ok(error instanceof ApiError);
            assert.equal(error.code, "local_data_already_claimed");
            return true;
          }
        );
        await assert.rejects(
          () => store.createChild("Post-claim Local Child", localIdentity),
          (error: unknown) => {
            assert.ok(error instanceof ApiError);
            assert.equal(error.code, "local_data_already_claimed");
            return true;
          }
        );
        await assert.rejects(
          () => store.createPairingSession(legacyChild.id, localIdentity),
          (error: unknown) => {
            assert.ok(error instanceof ApiError);
            assert.equal(error.code, "child_not_found");
            return true;
          }
        );
        await assert.rejects(
          () => store.consumePairing(
            {
              installationId: "stale-local-installation",
              deviceName: "Stale Local Device",
              qrToken: outstandingPairing.qrToken
            },
            { remoteAddress: "192.0.2.80" }
          ),
          (error: unknown) => {
            assert.ok(error instanceof ApiError);
            assert.equal(error.code, "pairing_session_consumed");
            return true;
          }
        );
      } finally {
        await store.close();
      }
    });

    await context.test("grant, re-pair, and settlement complete without deadlock", async () => {
      await resetDatabase(databaseUrl);
      const store = await PostgresPagePassStore.create({
        databaseUrl,
        parentToken,
        pepper,
        authMode: "local",
        now: () => initialNow
      });
      try {
        const child = await store.createChild("Concurrent Child");
        await store.grantCredit(child.id, {
          seconds: 3_600,
          reason: "Initial credit",
          idempotencyKey: "initial-credit"
        });
        const firstPairing = await store.createPairingSession(child.id);
        const firstDevice = await store.consumePairing(
          {
            installationId: "concurrent-installation",
            deviceName: "Concurrent Phone",
            qrToken: firstPairing.qrToken
          },
          { remoteAddress: "192.0.2.40" }
        );
        const replacementPairing = await store.createPairingSession(child.id);
        const settlement = {
          localSessionId: "three-way-session",
          requestedDurationSeconds: 900,
          balanceBeforeSeconds: 3_600,
          startedAt: "2026-07-17T12:00:00.000Z",
          expiresAt: "2026-07-17T12:15:00.000Z",
          endedAt: "2026-07-17T12:01:00.000Z",
          consumedSeconds: 59,
          endReason: "manual_stop" as const,
          idempotencyKey: "three-way-settlement"
        };

        const operations = Promise.allSettled([
          store.grantCredit(child.id, {
            seconds: 900,
            reason: "Concurrent credit",
            idempotencyKey: "concurrent-credit"
          }),
          store.consumePairing(
            {
              installationId: "concurrent-installation",
              deviceName: "Concurrent Phone",
              qrToken: replacementPairing.qrToken
            },
            { remoteAddress: "192.0.2.41" }
          ),
          store.settleEarnedTime(
            firstDevice.deviceCredential,
            settlement.localSessionId,
            settlement
          )
        ]);
        let timeout: ReturnType<typeof setTimeout> | undefined;
        const results = await Promise.race([
          operations,
          new Promise<never>((_resolve, reject) => {
            timeout = setTimeout(
              () => reject(new Error("Concurrent operations timed out")),
              5_000
            );
          })
        ]).finally(() => {
          if (timeout) {
            clearTimeout(timeout);
          }
        });

        assert.equal(results.length, 3);
        assert.equal(results[0]?.status, "fulfilled");
        assert.equal(results[1]?.status, "fulfilled");
        if (results[2]?.status === "rejected") {
          assert.ok(results[2].reason instanceof ApiError);
          assert.equal(results[2].reason.status, 401);
        }
      } finally {
        await store.close();
        await resetDatabase(databaseUrl);
      }
    });
  }
);
