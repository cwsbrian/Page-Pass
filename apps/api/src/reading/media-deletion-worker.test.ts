import assert from "node:assert/strict";
import test from "node:test";

import type { Prisma } from "../db/prisma.js";
import type { MediaStorage } from "./media-storage.js";
import { MediaDeletionWorker } from "./media-deletion-worker.js";

test("continuous media deletion remains scheduled after a successful sweep", async () => {
  const now = new Date("2026-08-07T12:00:00.000Z");
  const job = {
    id: "continuous-job",
    storageKey: "pending/late-upload",
    state: "pending",
    attemptCount: 0,
    continuousVerification: true,
    nextAttemptAt: now,
    lastError: null,
    completedAt: null
  };
  let deleteCount = 0;
  const prisma = {
    mediaDeletionJob: {
      findMany: async () => [job],
      updateMany: async ({ where, data }: {
        where: { state?: string; continuousVerification?: boolean };
        data: Record<string, unknown>;
      }) => {
        if (
          (where.state !== undefined && job.state !== where.state) ||
          (where.continuousVerification !== undefined &&
            job.continuousVerification !== where.continuousVerification)
        ) return { count: 0 };
        Object.assign(job, data);
        if (typeof data.attemptCount === "object") job.attemptCount += 1;
        return { count: 1 };
      },
      findUniqueOrThrow: async () => job
    }
  } as unknown as Prisma;
  const storage = {
    delete: async () => { deleteCount += 1; }
  } as unknown as MediaStorage;

  const worker = new MediaDeletionWorker(prisma, storage, {
    now: () => now.getTime()
  });
  await worker.drain();

  assert.equal(deleteCount, 1);
  assert.equal(job.state, "pending");
  assert.equal(job.attemptCount, 0);
  assert.equal(job.completedAt, null);
  assert.equal(
    job.nextAttemptAt.getTime(),
    now.getTime() + 24 * 60 * 60 * 1_000
  );
});

test("an archive promotion wins a race with a one-shot deletion", async () => {
  const now = new Date("2026-08-07T12:00:00.000Z");
  const promotedNextAttempt = new Date(now.getTime() + 60 * 60 * 1_000);
  const job = {
    id: "promoted-job",
    storageKey: "pending/promoted-upload",
    state: "pending",
    attemptCount: 0,
    continuousVerification: false,
    nextAttemptAt: now,
    lastError: null,
    completedAt: null
  };
  const prisma = {
    mediaDeletionJob: {
      findMany: async () => [job],
      updateMany: async ({ where, data }: {
        where: { state?: string; continuousVerification?: boolean };
        data: Record<string, unknown>;
      }) => {
        if (
          (where.state !== undefined && job.state !== where.state) ||
          (where.continuousVerification !== undefined &&
            job.continuousVerification !== where.continuousVerification)
        ) return { count: 0 };
        Object.assign(job, data);
        if (typeof data.attemptCount === "object") job.attemptCount += 1;
        return { count: 1 };
      },
      findUniqueOrThrow: async () => ({ ...job })
    }
  } as unknown as Prisma;
  const storage = {
    delete: async () => {
      job.state = "pending";
      job.attemptCount = 0;
      job.continuousVerification = true;
      job.nextAttemptAt = promotedNextAttempt;
    }
  } as unknown as MediaStorage;

  await new MediaDeletionWorker(prisma, storage, {
    now: () => now.getTime()
  }).drain();

  assert.equal(job.state, "pending");
  assert.equal(job.continuousVerification, true);
  assert.equal(job.nextAttemptAt, promotedNextAttempt);
  assert.equal(job.completedAt, null);
});
