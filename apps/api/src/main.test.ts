import assert from "node:assert/strict";
import test from "node:test";

import {
  childSnapshotSchema,
  earnedTimeSettlementSchema,
  type EarnedTimeSettlement
} from "../../../libs/shared/src/index.js";
import { ApiError, PagePassStore, type RequestIdentity } from "./domain.js";
import {
  createPagePassHttpServer,
  parseChildSnapshot,
  parsePagePassTrustedProxyAddresses,
  parsePagePassTrustProxy
} from "./main.js";

const parentToken = "test-parent-token";
const pepper = "test-only-server-pepper";
const startedAt = "2026-07-17T12:00:00.000Z";

function testStore(initialNow = Date.parse(startedAt)) {
  let now = initialNow;
  return {
    store: new PagePassStore({ parentToken, pepper, now: () => now }),
    advance(milliseconds: number) {
      now += milliseconds;
    }
  };
}

function pairChild(
  store: PagePassStore,
  childProfileId: string,
  installationId = "installation-a",
  deviceName = "Child iPhone"
) {
  const session = store.createPairingSession(childProfileId);
  return store.consumePairing(
    { installationId, deviceName, qrToken: session.qrToken },
    { remoteAddress: "192.0.2.1" }
  );
}

function settlement(
  overrides: Partial<EarnedTimeSettlement> = {}
): EarnedTimeSettlement {
  return {
    localSessionId: "local-session-1",
    requestedDurationSeconds: 900,
    balanceBeforeSeconds: 1_800,
    startedAt,
    expiresAt: "2026-07-17T12:15:00.000Z",
    endedAt: "2026-07-17T12:01:00.000Z",
    consumedSeconds: 60,
    endReason: "manual_stop",
    idempotencyKey: "settlement-1",
    ...overrides
  };
}

function expectApiError(
  action: () => unknown,
  status: number,
  code: string
): ApiError {
  let caught: unknown;
  try {
    action();
  } catch (error) {
    caught = error;
  }
  assert.ok(caught instanceof ApiError);
  assert.equal(caught.status, status);
  assert.equal(caught.code, code);
  return caught;
}

class IdentityCapturingStore extends PagePassStore {
  readonly remoteAddresses: string[] = [];

  createAppleAuthChallenge(identity: RequestIdentity) {
    this.remoteAddresses.push(identity.remoteAddress);
    return {
      challengeId: "test-challenge",
      nonce: "n".repeat(32),
      expiresAt: "2026-07-17T12:05:00.000Z"
    };
  }
}

async function challengeRemoteAddress(
  store: IdentityCapturingStore,
  trustedProxyAddresses: ReadonlySet<string>
): Promise<string> {
  const server = createPagePassHttpServer(store, { trustedProxyAddresses });
  await new Promise<void>((resolve, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", resolve);
  });
  try {
    const address = server.address();
    assert.ok(address !== null && typeof address !== "string");
    const response = await fetch(
      `http://127.0.0.1:${address.port}/v1/auth/apple/challenges`,
      {
        method: "POST",
        headers: {
          "content-type": "application/json",
          "x-forwarded-for": "198.51.100.20",
          "x-pagepass-client-ip": "203.0.113.10"
        },
        body: "{}"
      }
    );
    assert.equal(response.status, 201);
    return store.remoteAddresses.at(-1)!;
  } finally {
    await new Promise<void>((resolve, reject) => {
      server.close((error) => error === undefined ? resolve() : reject(error));
    });
  }
}

test("trusted proxy forwarding is explicit and strictly configured", async () => {
  assert.equal(parsePagePassTrustProxy(undefined), false);
  assert.equal(parsePagePassTrustProxy("false"), false);
  assert.equal(parsePagePassTrustProxy("true"), true);
  assert.throws(() => parsePagePassTrustProxy("TRUE"), /true or false/);
  assert.deepEqual(
    [...parsePagePassTrustedProxyAddresses("127.0.0.1, ::1")],
    ["127.0.0.1", "::1"]
  );
  assert.throws(
    () => parsePagePassTrustedProxyAddresses(undefined),
    /is required/
  );
  assert.throws(
    () => parsePagePassTrustedProxyAddresses("127.0.0.1, attacker"),
    /only IP addresses/
  );

  const store = new IdentityCapturingStore({ parentToken, pepper });
  const directAddress = await challengeRemoteAddress(store, new Set());
  assert.notEqual(directAddress, "203.0.113.10");
  assert.equal(
    await challengeRemoteAddress(store, new Set([directAddress])),
    "203.0.113.10"
  );
});

test("snapshot contract includes canonical synchronization metadata", () => {
  const snapshot = parseChildSnapshot({
    childProfileId: "child-1",
    childName: "Ada",
    balanceSeconds: 1_800,
    policyVersion: 1,
    ledgerRevision: 3,
    serverInstanceId: "550e8400-e29b-41d4-a716-446655440000",
    serverTime: "2026-07-17T12:00:00.000Z",
    lastSyncedAt: "2026-07-17T12:00:00.000Z"
  });

  assert.equal(snapshot.ledgerRevision, 3);
  assert.doesNotThrow(() => childSnapshotSchema.parse(snapshot));
});

test("snapshot server instance ID is stable per store and unique across stores", () => {
  const firstStore = testStore().store;
  const firstChild = firstStore.createChild("Ada");
  const firstDevice = pairChild(firstStore, firstChild.id);
  const firstSnapshot = firstStore.snapshot(firstDevice.deviceCredential);
  const repeatedSnapshot = firstStore.snapshot(firstDevice.deviceCredential);

  assert.match(firstSnapshot.serverInstanceId, /^[0-9a-f-]{36}$/);
  assert.equal(repeatedSnapshot.serverInstanceId, firstSnapshot.serverInstanceId);

  const secondStore = testStore().store;
  const secondChild = secondStore.createChild("Grace");
  const secondDevice = pairChild(secondStore, secondChild.id);
  const secondSnapshot = secondStore.snapshot(secondDevice.deviceCredential);

  assert.notEqual(secondSnapshot.serverInstanceId, firstSnapshot.serverInstanceId);
  assert.doesNotThrow(() => childSnapshotSchema.parse(firstSnapshot));
  assert.doesNotThrow(() => childSnapshotSchema.parse(secondSnapshot));
});

test("settlement contract enforces the wall-clock session envelope", () => {
  assert.throws(() => earnedTimeSettlementSchema.parse(settlement({
    requestedDurationSeconds: 899,
    expiresAt: "2026-07-17T12:14:59.000Z"
  })));
  assert.throws(() => earnedTimeSettlementSchema.parse(settlement({
    requestedDurationSeconds: 1_801,
    balanceBeforeSeconds: 1_800,
    expiresAt: "2026-07-17T12:30:01.000Z"
  })));
  assert.throws(() => earnedTimeSettlementSchema.parse(settlement({
    endReason: "expired",
    consumedSeconds: 900,
    endedAt: "2026-07-17T12:14:59.000Z"
  })));
});

test("QR and numeric code identify the same five-minute single-use session", () => {
  const { store, advance } = testStore();
  const child = store.createChild("Ada");
  const session = store.createPairingSession(child.id);

  assert.match(session.qrToken, /^[A-Za-z0-9_-]{43}$/);
  assert.match(session.numericCode, /^\d{6}$/);
  store.consumePairing(
    {
      installationId: "installation-a",
      deviceName: "Ada's iPhone",
      qrToken: session.qrToken
    },
    { remoteAddress: "192.0.2.10" }
  );
  expectApiError(
    () => store.consumePairing(
      {
        installationId: "installation-a",
        deviceName: "Ada's iPhone",
        numericCode: session.numericCode
      },
      { remoteAddress: "192.0.2.10" }
    ),
    409,
    "pairing_session_consumed"
  );

  const expiring = store.createPairingSession(store.createChild("Grace").id);
  advance(5 * 60 * 1_000);
  expectApiError(
    () => store.consumePairing(
      {
        installationId: "installation-b",
        deviceName: "Grace's iPad",
        qrToken: expiring.qrToken
      },
      { remoteAddress: "192.0.2.11" }
    ),
    410,
    "pairing_session_expired"
  );
});

test("a different installation cannot replace the active child device", () => {
  const { store } = testStore();
  const child = store.createChild("Ada");
  const first = pairChild(store, child.id);
  const replacementSession = store.createPairingSession(child.id);

  expectApiError(
    () => store.consumePairing(
      {
        installationId: "installation-b",
        deviceName: "Other iPhone",
        qrToken: replacementSession.qrToken
      },
      { remoteAddress: "192.0.2.20" }
    ),
    409,
    "active_device_exists"
  );
  assert.equal(store.snapshot(first.deviceCredential).childProfileId, child.id);

  const rotated = store.consumePairing(
    {
      installationId: "installation-a",
      deviceName: "Renamed iPhone",
      numericCode: replacementSession.numericCode
    },
    { remoteAddress: "192.0.2.20" }
  );
  expectApiError(() => store.snapshot(first.deviceCredential), 401, "unauthorized");
  assert.equal(store.snapshot(rotated.deviceCredential).childProfileId, child.id);
});

test("one installation cannot be active for two child profiles", () => {
  const { store } = testStore();
  const ada = store.createChild("Ada");
  const grace = store.createChild("Grace");
  const adaDevice = pairChild(store, ada.id, "shared-installation", "Shared iPhone");
  const graceSession = store.createPairingSession(grace.id);

  expectApiError(
    () => store.consumePairing(
      {
        installationId: "shared-installation",
        deviceName: "Shared iPhone",
        qrToken: graceSession.qrToken
      },
      { remoteAddress: "192.0.2.21" }
    ),
    409,
    "installation_already_bound"
  );

  assert.equal(store.snapshot(adaDevice.deviceCredential).childProfileId, ada.id);
  const graceDevice = store.consumePairing(
    {
      installationId: "grace-installation",
      deviceName: "Grace iPad",
      numericCode: graceSession.numericCode
    },
    { remoteAddress: "192.0.2.22" }
  );
  assert.equal(store.snapshot(graceDevice.deviceCredential).childProfileId, grace.id);
});

test("numeric code attempts are limited independently by installation and address", () => {
  const first = testStore();
  for (let attempt = 0; attempt < 5; attempt += 1) {
    expectApiError(
      () => first.store.consumePairing(
        {
          installationId: "same-installation",
          deviceName: "Phone",
          numericCode: "999999"
        },
        { remoteAddress: `192.0.2.${attempt + 1}` }
      ),
      401,
      "invalid_pairing_secret"
    );
  }
  expectApiError(
    () => first.store.consumePairing(
      {
        installationId: "same-installation",
        deviceName: "Phone",
        numericCode: "999999"
      },
      { remoteAddress: "192.0.2.99" }
    ),
    429,
    "pairing_rate_limited"
  );

  const second = testStore();
  for (let attempt = 0; attempt < 5; attempt += 1) {
    expectApiError(
      () => second.store.consumePairing(
        {
          installationId: `installation-${attempt}`,
          deviceName: "Phone",
          numericCode: "999999"
        },
        { remoteAddress: "198.51.100.1" }
      ),
      401,
      "invalid_pairing_secret"
    );
  }
  expectApiError(
    () => second.store.consumePairing(
      {
        installationId: "installation-6",
        deviceName: "Phone",
        numericCode: "999999"
      },
      { remoteAddress: "198.51.100.1" }
    ),
    429,
    "pairing_rate_limited"
  );

  second.advance(5 * 60 * 1_000);
  expectApiError(
    () => second.store.consumePairing(
      {
        installationId: "installation-after-window",
        deviceName: "Phone",
        numericCode: "999999"
      },
      { remoteAddress: "198.51.100.1" }
    ),
    401,
    "invalid_pairing_secret"
  );
});

test("earn and spend rows are idempotent and advance revision only on commit", () => {
  const { store } = testStore();
  const child = store.createChild("Ada");
  const paired = pairChild(store, child.id);
  const grantInput = {
    seconds: 1_800,
    reason: "Read for half an hour",
    idempotencyKey: "grant-1"
  };

  const grant = store.grantCredit(child.id, grantInput);
  assert.deepEqual(store.grantCredit(child.id, grantInput), grant);
  expectApiError(
    () => store.grantCredit(child.id, { ...grantInput, seconds: 301 }),
    409,
    "idempotency_conflict"
  );
  assert.equal(store.snapshot(paired.deviceCredential).ledgerRevision, 1);

  const input = settlement();
  const spend = store.settleEarnedTime(
    paired.deviceCredential,
    input.localSessionId,
    input
  );
  assert.deepEqual(
    store.settleEarnedTime(paired.deviceCredential, input.localSessionId, input),
    spend
  );
  expectApiError(
    () => store.settleEarnedTime(
      paired.deviceCredential,
      input.localSessionId,
      { ...input, consumedSeconds: 61 }
    ),
    409,
    "idempotency_conflict"
  );
  expectApiError(
    () => store.settleEarnedTime(
      paired.deviceCredential,
      input.localSessionId,
      { ...input, idempotencyKey: "settlement-2" }
    ),
    409,
    "session_already_settled"
  );

  const snapshot = store.snapshot(paired.deviceCredential);
  assert.equal(snapshot.balanceSeconds, 1_740);
  assert.equal(snapshot.ledgerRevision, 2);
});

test("settlements use credential ownership and server-computed spend", () => {
  const { store } = testStore();
  const ada = store.createChild("Ada");
  const grace = store.createChild("Grace");
  const adaDevice = pairChild(store, ada.id, "ada-installation", "Ada Phone");
  const graceDevice = pairChild(store, grace.id, "grace-installation", "Grace Phone");
  store.grantCredit(ada.id, {
    seconds: 1_800,
    reason: "Ada earned time",
    idempotencyKey: "ada-grant"
  });
  store.grantCredit(grace.id, {
    seconds: 3_600,
    reason: "Grace earned time",
    idempotencyKey: "grace-grant"
  });

  const mismatched = settlement({ balanceBeforeSeconds: 999_999, consumedSeconds: 59 });
  const canonicalSpend = store.settleEarnedTime(
    adaDevice.deviceCredential,
    mismatched.localSessionId,
    mismatched
  );
  assert.equal(canonicalSpend.consumedSeconds, 60);
  assert.equal(store.snapshot(adaDevice.deviceCredential).balanceSeconds, 1_740);
  assert.equal(store.snapshot(graceDevice.deviceCredential).balanceSeconds, 3_600);

  const insufficient = settlement({
    localSessionId: "too-large",
    requestedDurationSeconds: 1_800,
    balanceBeforeSeconds: 1_800,
    expiresAt: "2026-07-17T12:30:00.000Z",
    consumedSeconds: 1_800,
    endedAt: "2026-07-17T12:30:00.000Z",
    idempotencyKey: "too-large"
  });
  expectApiError(
    () => store.settleEarnedTime(
      adaDevice.deviceCredential,
      insufficient.localSessionId,
      insufficient
    ),
    422,
    "insufficient_balance"
  );

  assert.throws(
    () => earnedTimeSettlementSchema.parse({
      ...settlement(),
      childProfileId: grace.id,
      installationId: "forged-installation"
    })
  );
});

test("HTTP routes enforce parent and child bearer boundaries with JSON errors", async (context) => {
  const { store } = testStore();
  const server = createPagePassHttpServer(store);
  await new Promise<void>((resolve, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", resolve);
  });
  context.after(() => new Promise<void>((resolve, reject) => {
    server.close((error) => error === undefined ? resolve() : reject(error));
  }));

  const address = server.address();
  assert.ok(address !== null && typeof address !== "string");
  const baseUrl = `http://127.0.0.1:${address.port}`;
  const parentHeaders = {
    authorization: `Bearer ${parentToken}`,
    "content-type": "application/json"
  };

  const health = await fetch(`${baseUrl}/health`);
  assert.deepEqual(await health.json(), { status: "ok" });

  const createResponse = await fetch(`${baseUrl}/v1/parent/children`, {
    method: "POST",
    headers: parentHeaders,
    body: JSON.stringify({ name: "Ada" })
  });
  assert.equal(createResponse.status, 201);
  const child = await createResponse.json() as { id: string };

  const pairingResponse = await fetch(
    `${baseUrl}/v1/parent/children/${child.id}/pairing-sessions`,
    { method: "POST", headers: parentHeaders, body: "{}" }
  );
  assert.equal(pairingResponse.status, 201);
  const pairing = await pairingResponse.json() as { qrToken: string };

  const consumeResponse = await fetch(`${baseUrl}/v1/pairing/consume`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      installationId: "http-installation",
      deviceName: "HTTP iPhone",
      qrToken: pairing.qrToken
    })
  });
  assert.equal(consumeResponse.status, 200);
  const consumed = await consumeResponse.json() as { deviceCredential: string };
  const childHeaders = {
    authorization: `Bearer ${consumed.deviceCredential}`,
    "content-type": "application/json"
  };

  const snapshotResponse = await fetch(`${baseUrl}/v1/child/snapshot`, {
    headers: childHeaders
  });
  assert.equal(snapshotResponse.status, 200);
  assert.equal(
    (await snapshotResponse.json() as { childProfileId: string }).childProfileId,
    child.id
  );

  const forbiddenParentMutation = await fetch(
    `${baseUrl}/v1/parent/children/${child.id}/credit-grants`,
    {
      method: "POST",
      headers: childHeaders,
      body: JSON.stringify({
        seconds: 60,
        reason: "Forged grant",
        idempotencyKey: "forged"
      })
    }
  );
  assert.equal(forbiddenParentMutation.status, 401);
  assert.deepEqual(await forbiddenParentMutation.json(), {
    error: {
      code: "unauthorized",
      message: "The parent bearer token is invalid"
    }
  });

  const forgedSettlement = await fetch(
    `${baseUrl}/v1/child/earned-time-sessions/forged-session`,
    {
      method: "PUT",
      headers: childHeaders,
      body: JSON.stringify({
        ...settlement({ localSessionId: "forged-session" }),
        childProfileId: child.id
      })
    }
  );
  assert.equal(forgedSettlement.status, 400);
  assert.equal(
    (await forgedSettlement.json() as { error: { code: string } }).error.code,
    "invalid_request"
  );

  const parentOnChildRoute = await fetch(`${baseUrl}/v1/child/snapshot`, {
    headers: parentHeaders
  });
  assert.equal(parentOnChildRoute.status, 401);
});
