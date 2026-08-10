import assert from "node:assert/strict";
import test from "node:test";

import { DataRetentionWorker } from "./data-retention-worker.js";

test("retention removes only expired operational data", async () => {
  const calls: Array<{ model: string; where: unknown }> = [];
  const model = (name: string) => ({
    deleteMany: (input: { where: unknown }) => {
      calls.push({ model: name, where: input.where });
      return Promise.resolve({ count: 0 });
    }
  });
  const prisma = {
    session: model("session"),
    verification: model("verification"),
    appleAuthChallenge: model("appleAuthChallenge"),
    parentSession: model("parentSession"),
    pairingRateAttempt: model("pairingRateAttempt"),
    pairingSession: model("pairingSession"),
    legacyPairingSession: model("legacyPairingSession"),
    deviceCredential: model("deviceCredential"),
    parentPushDevice: model("parentPushDevice"),
    childPushDevice: model("childPushDevice"),
    deviceStatusReport: model("deviceStatusReport"),
    pushOutboxEvent: model("pushOutboxEvent"),
    mediaDeletionJob: model("mediaDeletionJob"),
    $transaction: async (operations: Promise<unknown>[]) => Promise.all(operations)
  };
  const now = Date.UTC(2026, 7, 6, 12);

  await new DataRetentionWorker(prisma as never, { now: () => now }).drain();

  assert.deepEqual(calls.map((call) => call.model), [
    "session",
    "verification",
    "appleAuthChallenge",
    "parentSession",
    "pairingRateAttempt",
    "pairingSession",
    "legacyPairingSession",
    "deviceCredential",
    "parentPushDevice",
    "childPushDevice",
    "deviceStatusReport",
    "pushOutboxEvent",
    "mediaDeletionJob"
  ]);
  assert.deepEqual(calls[0]?.where, {
    expiresAt: { lte: new Date(now) }
  });
  assert.deepEqual(calls[4]?.where, {
    attemptedAt: { lte: new Date(now - 24 * 60 * 60 * 1_000) }
  });
  assert.deepEqual(calls[11]?.where, {
    state: { in: ["sent", "failed"] },
    updatedAt: { lte: new Date(now - 30 * 24 * 60 * 60 * 1_000) }
  });
});

test("retention reports background failures", async () => {
  const expected = new Error("retention database unavailable");
  const reported = deferred<unknown>();
  const worker = new DataRetentionWorker({
    session: { deleteMany: () => Promise.reject(expected) },
    verification: { deleteMany: () => Promise.resolve({ count: 0 }) },
    appleAuthChallenge: { deleteMany: () => Promise.resolve({ count: 0 }) },
    parentSession: { deleteMany: () => Promise.resolve({ count: 0 }) },
    pairingRateAttempt: { deleteMany: () => Promise.resolve({ count: 0 }) },
    pairingSession: { deleteMany: () => Promise.resolve({ count: 0 }) },
    legacyPairingSession: { deleteMany: () => Promise.resolve({ count: 0 }) },
    deviceCredential: { deleteMany: () => Promise.resolve({ count: 0 }) },
    parentPushDevice: { deleteMany: () => Promise.resolve({ count: 0 }) },
    childPushDevice: { deleteMany: () => Promise.resolve({ count: 0 }) },
    deviceStatusReport: { deleteMany: () => Promise.resolve({ count: 0 }) },
    pushOutboxEvent: { deleteMany: () => Promise.resolve({ count: 0 }) },
    mediaDeletionJob: { deleteMany: () => Promise.resolve({ count: 0 }) },
    $transaction: (operations: Promise<unknown>[]) => Promise.all(operations)
  } as never, {
    intervalMs: 60_000,
    onError: reported.resolve
  });

  try {
    worker.start();
    assert.equal(await reported.promise, expected);
  } finally {
    worker.close();
  }
});

function deferred<T>() {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>((complete) => { resolve = complete; });
  return { promise, resolve };
}
