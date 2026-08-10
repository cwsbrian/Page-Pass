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
const pepper = "postgres-auth-test-pepper";
const localParentToken = "postgres-auth-local-parent";
const initialNow = Date.parse("2026-07-17T12:00:00.000Z");

class FakeAppleIdentityTokenVerifier implements AppleIdentityTokenVerifier {
  private readonly identities = new Map<string, VerifiedAppleIdentity>();

  set(
    token: string,
    identity: Omit<VerifiedAppleIdentity, "issuer">
  ): void {
    this.identities.set(token, { issuer: appleIdentityIssuer, ...identity });
  }

  async verify(identityToken: string): Promise<VerifiedAppleIdentity> {
    const identity = this.identities.get(identityToken);
    if (identity === undefined) throw new Error("Unknown fake Apple token");
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
        legacy_pairing_sessions,
        pairing_sessions,
        children,
        server_state
      CASCADE
    `);
    await sql`
      DELETE FROM parent_accounts
      WHERE id <> '00000000-0000-4000-8000-000000000001'
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

async function jsonRequest(
  url: string,
  options: RequestInit = {}
): Promise<{ response: Response; body: unknown }> {
  const response = await fetch(url, options);
  const text = await response.text();
  return {
    response,
    body: text.length === 0 ? undefined : JSON.parse(text)
  };
}

function bearer(token: string): Record<string, string> {
  return {
    authorization: `Bearer ${token}`,
    "content-type": "application/json"
  };
}

async function createChallenge(baseUrl: string): Promise<{
  challengeId: string;
  nonce: string;
  expiresAt: string;
}> {
  const { response, body } = await jsonRequest(
    `${baseUrl}/v1/auth/apple/challenges`,
    { method: "POST", headers: { "content-type": "application/json" }, body: "{}" }
  );
  assert.equal(response.status, 201);
  return body as { challengeId: string; nonce: string; expiresAt: string };
}

async function createAppleSession(
  baseUrl: string,
  verifier: FakeAppleIdentityTokenVerifier,
  subject: string,
  token: string,
  displayName: string
): Promise<{
  sessionToken: string;
  parent: { id: string; displayName: string };
}> {
  const challenge = await createChallenge(baseUrl);
  verifier.set(token, {
    subject,
    nonce: challenge.nonce,
    email: `${subject}@example.test`
  });
  const { response, body } = await jsonRequest(`${baseUrl}/v1/auth/apple/sessions`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      challengeId: challenge.challengeId,
      state: challenge.challengeId,
      identityToken: token,
      displayName
    })
  });
  assert.equal(response.status, 201);
  return body as {
    sessionToken: string;
    parent: { id: string; displayName: string };
  };
}

function assertErrorCode(body: unknown, code: string): void {
  assert.equal((body as { error: { code: string } }).error.code, code);
}

test(
  "PostgreSQL parent authentication",
  { skip: databaseUrl === undefined ? "TEST_DATABASE_URL is not set" : false },
  async (context) => {
    assert.ok(databaseUrl !== undefined);

    await context.test("Apple challenges, sessions, and parent isolation", async () => {
      await resetDatabase(databaseUrl);
      let now = initialNow;
      const verifier = new FakeAppleIdentityTokenVerifier();
      const store = await PostgresPagePassStore.create({
        databaseUrl,
        pepper,
        authMode: "apple",
        appleTokenVerifier: verifier,
        now: () => now
      });
      const server = await startTestServer(store);
      try {
        const replayChallenge = await createChallenge(server.baseUrl);
        verifier.set("replay-token", {
          subject: "parent-replay",
          nonce: replayChallenge.nonce
        });
        const replayInput = {
          challengeId: replayChallenge.challengeId,
          state: replayChallenge.challengeId,
          identityToken: "replay-token",
          displayName: "Replay Parent"
        };
        const firstUse = await jsonRequest(`${server.baseUrl}/v1/auth/apple/sessions`, {
          method: "POST",
          headers: { "content-type": "application/json" },
          body: JSON.stringify(replayInput)
        });
        assert.equal(firstUse.response.status, 201);
        const replay = await jsonRequest(`${server.baseUrl}/v1/auth/apple/sessions`, {
          method: "POST",
          headers: { "content-type": "application/json" },
          body: JSON.stringify(replayInput)
        });
        assert.equal(replay.response.status, 409);
        assertErrorCode(replay.body, "apple_challenge_consumed");

        const wrongStateChallenge = await createChallenge(server.baseUrl);
        verifier.set("wrong-state-token", {
          subject: "parent-state",
          nonce: wrongStateChallenge.nonce
        });
        const wrongState = await jsonRequest(`${server.baseUrl}/v1/auth/apple/sessions`, {
          method: "POST",
          headers: { "content-type": "application/json" },
          body: JSON.stringify({
            challengeId: wrongStateChallenge.challengeId,
            state: "wrong-state",
            identityToken: "wrong-state-token"
          })
        });
        assert.equal(wrongState.response.status, 401);
        assertErrorCode(wrongState.body, "invalid_apple_state");

        const wrongNonceChallenge = await createChallenge(server.baseUrl);
        verifier.set("wrong-nonce-token", {
          subject: "parent-nonce",
          nonce: "wrong-nonce-value"
        });
        const wrongNonce = await jsonRequest(`${server.baseUrl}/v1/auth/apple/sessions`, {
          method: "POST",
          headers: { "content-type": "application/json" },
          body: JSON.stringify({
            challengeId: wrongNonceChallenge.challengeId,
            state: wrongNonceChallenge.challengeId,
            identityToken: "wrong-nonce-token"
          })
        });
        assert.equal(wrongNonce.response.status, 401);
        assertErrorCode(wrongNonce.body, "invalid_apple_nonce");

        const expiringChallenge = await createChallenge(server.baseUrl);
        verifier.set("expired-challenge-token", {
          subject: "parent-expired-challenge",
          nonce: expiringChallenge.nonce
        });
        now += 5 * 60 * 1_000;
        const expiredChallenge = await jsonRequest(
          `${server.baseUrl}/v1/auth/apple/sessions`,
          {
            method: "POST",
            headers: { "content-type": "application/json" },
            body: JSON.stringify({
              challengeId: expiringChallenge.challengeId,
              state: expiringChallenge.challengeId,
              identityToken: "expired-challenge-token"
            })
          }
        );
        assert.equal(expiredChallenge.response.status, 410);
        assertErrorCode(expiredChallenge.body, "apple_challenge_expired");
        now -= 5 * 60 * 1_000;

        const raceChallenge = await store.createAppleAuthChallenge();
        verifier.set("race-token", {
          subject: "parent-race",
          nonce: raceChallenge.nonce
        });
        const raceInput = {
          challengeId: raceChallenge.challengeId,
          state: raceChallenge.challengeId,
          identityToken: "race-token"
        };
        const raceResults = await Promise.allSettled([
          store.createAppleSession(raceInput),
          store.createAppleSession(raceInput)
        ]);
        assert.equal(
          raceResults.filter((result) => result.status === "fulfilled").length,
          1
        );
        const raceFailure = raceResults.find((result) => result.status === "rejected");
        assert.ok(raceFailure?.status === "rejected");
        assert.ok(raceFailure.reason instanceof ApiError);
        assert.equal(raceFailure.reason.code, "apple_challenge_consumed");

        const parentA = await createAppleSession(
          server.baseUrl,
          verifier,
          "parent-a",
          "parent-a-token",
          "Parent A"
        );
        const parentB = await createAppleSession(
          server.baseUrl,
          verifier,
          "parent-b",
          "parent-b-token",
          "Parent B"
        );

        const me = await jsonRequest(`${server.baseUrl}/v1/parent/me`, {
          headers: bearer(parentA.sessionToken)
        });
        assert.equal(me.response.status, 200);
        assert.deepEqual(me.body, parentA.parent);

        const childAResponse = await jsonRequest(
          `${server.baseUrl}/v1/parent/children`,
          {
            method: "POST",
            headers: bearer(parentA.sessionToken),
            body: JSON.stringify({ name: "Ada" })
          }
        );
        const childA = childAResponse.body as { id: string };
        const childBResponse = await jsonRequest(
          `${server.baseUrl}/v1/parent/children`,
          {
            method: "POST",
            headers: bearer(parentB.sessionToken),
            body: JSON.stringify({ name: "Grace" })
          }
        );
        assert.equal(childAResponse.response.status, 201);
        assert.equal(childBResponse.response.status, 201);

        const parentAChildren = await jsonRequest(
          `${server.baseUrl}/v1/parent/children`,
          { headers: bearer(parentA.sessionToken) }
        );
        const parentBChildren = await jsonRequest(
          `${server.baseUrl}/v1/parent/children`,
          { headers: bearer(parentB.sessionToken) }
        );
        assert.equal((parentAChildren.body as { children: unknown[] }).children.length, 1);
        assert.equal((parentBChildren.body as { children: unknown[] }).children.length, 1);

        const forgedPairing = await jsonRequest(
          `${server.baseUrl}/v1/parent/children/${childA.id}/pairing-sessions`,
          { method: "POST", headers: bearer(parentB.sessionToken), body: "{}" }
        );
        assert.equal(forgedPairing.response.status, 404);
        assertErrorCode(forgedPairing.body, "child_not_found");

        const forgedGrant = await jsonRequest(
          `${server.baseUrl}/v1/parent/children/${childA.id}/credit-grants`,
          {
            method: "POST",
            headers: bearer(parentB.sessionToken),
            body: JSON.stringify({
              seconds: 900,
              reason: "Forged",
              idempotencyKey: "forged-parent-grant"
            })
          }
        );
        assert.equal(forgedGrant.response.status, 404);
        assertErrorCode(forgedGrant.body, "child_not_found");

        const revoke = await jsonRequest(`${server.baseUrl}/v1/auth/session`, {
          method: "DELETE",
          headers: bearer(parentA.sessionToken)
        });
        assert.equal(revoke.response.status, 204);
        const revokedMe = await jsonRequest(`${server.baseUrl}/v1/parent/me`, {
          headers: bearer(parentA.sessionToken)
        });
        assert.equal(revokedMe.response.status, 401);

        const expiring = await createAppleSession(
          server.baseUrl,
          verifier,
          "parent-expiring",
          "parent-expiring-token",
          "Expiring Parent"
        );
        now += 7 * 24 * 60 * 60 * 1_000;
        await assert.rejects(
          () => store.authenticateParent(expiring.sessionToken),
          (error: unknown) => {
            assert.ok(error instanceof ApiError);
            assert.equal(error.code, "unauthorized");
            return true;
          }
        );
      } finally {
        await server.close();
        await store.close();
      }
    });

    await context.test("local parent token remains compatible", async () => {
      await resetDatabase(databaseUrl);
      const store = await PostgresPagePassStore.create({
        databaseUrl,
        parentToken: localParentToken,
        pepper,
        authMode: "local",
        now: () => initialNow
      });
      const server = await startTestServer(store);
      try {
        const me = await jsonRequest(`${server.baseUrl}/v1/parent/me`, {
          headers: bearer(localParentToken)
        });
        assert.equal(me.response.status, 200);
        assert.deepEqual(me.body, {
          id: "00000000-0000-4000-8000-000000000001",
          displayName: "Local Parent"
        });

        const child = await jsonRequest(`${server.baseUrl}/v1/parent/children`, {
          method: "POST",
          headers: bearer(localParentToken),
          body: JSON.stringify({ name: "Local Child" })
        });
        assert.equal(child.response.status, 201);
        const children = await jsonRequest(`${server.baseUrl}/v1/parent/children`, {
          headers: bearer(localParentToken)
        });
        assert.equal((children.body as { children: unknown[] }).children.length, 1);
      } finally {
        await server.close();
        await store.close();
        await resetDatabase(databaseUrl);
      }
    });
  }
);
