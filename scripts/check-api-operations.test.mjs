import assert from "node:assert/strict";
import test from "node:test";

import {
  evaluateOperationalHealth,
  parseOperationalThresholds
} from "./check-api-operations.mjs";

const healthySnapshot = {
  pushDueCount: 2,
  pushOldestDueSeconds: 30,
  pushFailedCount: 0,
  pushProcessingSeconds: 0,
  mediaDueCount: 1,
  mediaOldestDueSeconds: 60,
  mediaMaxAttemptCount: 1,
  mediaProcessingSeconds: 0
};

test("operations check accepts values at or below every threshold", () => {
  const thresholds = parseOperationalThresholds({
    PAGEPASS_OPS_MAX_PUSH_DUE: "2",
    PAGEPASS_OPS_MAX_PUSH_DELAY_SECONDS: "30",
    PAGEPASS_OPS_MAX_PUSH_FAILED: "0",
    PAGEPASS_OPS_MAX_PUSH_PROCESSING_SECONDS: "0",
    PAGEPASS_OPS_MAX_MEDIA_DUE: "1",
    PAGEPASS_OPS_MAX_MEDIA_DELAY_SECONDS: "60",
    PAGEPASS_OPS_MAX_MEDIA_ATTEMPTS: "1",
    PAGEPASS_OPS_MAX_MEDIA_PROCESSING_SECONDS: "0"
  });
  const result = evaluateOperationalHealth(healthySnapshot, thresholds);
  assert.equal(result.ok, true);
  assert.ok(result.checks.every((check) => check.ok));
});

test("operations check reports each exceeded threshold without row data", () => {
  const thresholds = parseOperationalThresholds({
    PAGEPASS_OPS_MAX_PUSH_DUE: "1"
  });
  const result = evaluateOperationalHealth(healthySnapshot, thresholds);
  assert.equal(result.ok, false);
  assert.deepEqual(
    result.checks.filter((check) => !check.ok).map((check) => check.name),
    ["pushDueCount"]
  );
  assert.equal(JSON.stringify(result).includes("storageKey"), false);
  assert.equal(JSON.stringify(result).includes("payload"), false);
});

test("operations thresholds reject malformed and unsafe values", () => {
  assert.throws(
    () => parseOperationalThresholds({ PAGEPASS_OPS_MAX_PUSH_DUE: "-1" }),
    /nonnegative integer/
  );
  assert.throws(
    () => parseOperationalThresholds({ PAGEPASS_OPS_MAX_PUSH_DUE: "1.5" }),
    /nonnegative integer/
  );
  assert.throws(
    () => parseOperationalThresholds({
      PAGEPASS_OPS_MAX_PUSH_DUE: "9007199254740992"
    }),
    /outside the supported range/
  );
});
