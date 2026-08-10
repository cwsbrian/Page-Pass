import assert from "node:assert/strict";
import test from "node:test";

import { MediaDeletionWorker } from "../reading/media-deletion-worker.js";
import type { MediaStorage } from "../reading/media-storage.js";
import {
  notificationPayload,
  parentPreferenceFilter,
  PrismaPushNotificationService
} from "./push-service.js";

test("parent push event types map to their notification preference", () => {
  assert.deepEqual(parentPreferenceFilter("reading_submission_submitted"), {
    readingRequestsEnabled: true
  });
  assert.deepEqual(parentPreferenceFilter("app_request_created"), {
    appRequestsEnabled: true
  });
  assert.deepEqual(parentPreferenceFilter("device_attention_required"), {
    deviceAlertsEnabled: true
  });
  assert.deepEqual(parentPreferenceFilter("earned_time_session_ended"), {
    sessionEndedEnabled: true
  });
  assert.equal(parentPreferenceFilter("unknown"), undefined);
});

test("reading submission push opens the exact report", () => {
  assert.deepEqual(notificationPayload({
    childProfileId: "child-1",
    eventType: "reading_submission_submitted",
    payload: {
      childName: "Alex",
      bookTitle: "Charlotte's Web",
      submissionId: "submission-1"
    }
  }), {
    aps: {
      alert: {
        title: "New reading report",
        body: "Alex submitted Charlotte's Web."
      },
      sound: "default",
      "thread-id": "pagepass-child-child-1"
    },
    pagePass: {
      type: "reading_submission_submitted",
      childProfileId: "child-1",
      submissionId: "submission-1"
    }
  });
});

test("approved reading review tells the child about earned time", () => {
  assert.deepEqual(notificationPayload({
    childProfileId: "child-1",
    eventType: "reading_submission_reviewed",
    payload: {
      bookTitle: "Charlotte's Web",
      submissionId: "submission-1",
      decision: "approved",
      rewardSeconds: 900
    }
  }), {
    aps: {
      alert: {
        title: "Reading report approved",
        body: "Charlotte's Web was approved. You earned 15 min."
      },
      sound: "default",
      "thread-id": "pagepass-child-child-1"
    },
    pagePass: {
      type: "reading_submission_reviewed",
      childProfileId: "child-1",
      submissionId: "submission-1"
    }
  });
});

test("changes requested push opens the report feedback", () => {
  const result = notificationPayload({
    childProfileId: "child-1",
    eventType: "reading_submission_reviewed",
    payload: {
      bookTitle: "Charlotte's Web",
      submissionId: "submission-1",
      decision: "changes_requested",
      rewardSeconds: 0
    }
  });
  assert.deepEqual((result.aps as { alert: unknown }).alert, {
    title: "Changes requested",
    body: "Your parent left feedback on Charlotte's Web."
  });
});

test("device and session events produce parent alerts", () => {
  const device = notificationPayload({
    childProfileId: "child-1",
    eventType: "device_attention_required",
    payload: { childName: "Alex" }
  });
  assert.deepEqual((device.aps as { alert: unknown }).alert, {
    title: "Device needs attention",
    body: "Alex's device could not apply its app restrictions."
  });

  const session = notificationPayload({
    childProfileId: "child-1",
    eventType: "earned_time_session_ended",
    payload: { childName: "Alex" }
  });
  assert.deepEqual((session.aps as { alert: unknown }).alert, {
    title: "Earned Time ended",
    body: "Alex's apps are locked again."
  });
});

test("background workers report database outages without unhandled rejection", async () => {
  const pushFailure = new Error("push database unavailable");
  const mediaFailure = new Error("media database unavailable");
  const pushReported = deferred<unknown>();
  const mediaReported = deferred<unknown>();
  const push = new PrismaPushNotificationService({
    pushOutboxEvent: {
      updateMany: async () => ({ count: 0 }),
      findMany: async () => { throw pushFailure; }
    }
  } as never, {
    pepper: "test-pepper",
    sender: {
      send: async () => ({
        accepted: true,
        status: 200,
        invalidDeviceToken: false
      }),
      close: () => undefined
    },
    onError: pushReported.resolve
  });
  const media = new MediaDeletionWorker({
    mediaDeletionJob: {
      updateMany: async () => ({ count: 0 }),
      findMany: async () => { throw mediaFailure; }
    }
  } as never, {} as MediaStorage, {
    intervalMs: 60_000,
    onError: mediaReported.resolve
  });

  try {
    await push.start();
    await media.start();
    assert.equal(await pushReported.promise, pushFailure);
    assert.equal(await mediaReported.promise, mediaFailure);
  } finally {
    push.close();
    media.close();
  }
});

function deferred<T>() {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>((complete) => { resolve = complete; });
  return { promise, resolve };
}
