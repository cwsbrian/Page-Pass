import { resolve } from "node:path";
import { pathToFileURL } from "node:url";

import postgres from "postgres";

const thresholdDefinitions = {
  pushDueCount: ["PAGEPASS_OPS_MAX_PUSH_DUE", 100],
  pushOldestDueSeconds: ["PAGEPASS_OPS_MAX_PUSH_DELAY_SECONDS", 300],
  pushFailedCount: ["PAGEPASS_OPS_MAX_PUSH_FAILED", 10],
  pushProcessingSeconds: ["PAGEPASS_OPS_MAX_PUSH_PROCESSING_SECONDS", 300],
  mediaDueCount: ["PAGEPASS_OPS_MAX_MEDIA_DUE", 100],
  mediaOldestDueSeconds: ["PAGEPASS_OPS_MAX_MEDIA_DELAY_SECONDS", 3_600],
  mediaMaxAttemptCount: ["PAGEPASS_OPS_MAX_MEDIA_ATTEMPTS", 10],
  mediaProcessingSeconds: ["PAGEPASS_OPS_MAX_MEDIA_PROCESSING_SECONDS", 300]
};

export function parseOperationalThresholds(environment = process.env) {
  return Object.fromEntries(
    Object.entries(thresholdDefinitions).map(([field, [name, fallback]]) => [
      field,
      parseNonnegativeInteger(environment[name], name, fallback)
    ])
  );
}

export function evaluateOperationalHealth(snapshot, thresholds) {
  const checks = Object.entries(thresholdDefinitions).map(([field, [name]]) => {
    const actual = snapshot[field];
    const maximum = thresholds[field];
    return {
      name: field,
      actual,
      maximum,
      ok: actual <= maximum,
      thresholdEnvironment: name
    };
  });
  return {
    ok: checks.every((check) => check.ok),
    checkedAt: new Date().toISOString(),
    snapshot,
    checks
  };
}

export async function queryOperationalSnapshot(sql) {
  const rows = await sql`
    SELECT
      COUNT(*) FILTER (
        WHERE push.state = 'pending'
          AND push.next_attempt_at <= CURRENT_TIMESTAMP
      )::int AS push_due_count,
      COALESCE(EXTRACT(EPOCH FROM (
        CURRENT_TIMESTAMP - MIN(push.created_at) FILTER (
          WHERE push.state = 'pending'
            AND push.next_attempt_at <= CURRENT_TIMESTAMP
        )
      )), 0)::float8 AS push_oldest_due_seconds,
      COUNT(*) FILTER (WHERE push.state = 'failed')::int AS push_failed_count,
      COALESCE(EXTRACT(EPOCH FROM (
        CURRENT_TIMESTAMP - MIN(push.updated_at) FILTER (
          WHERE push.state = 'processing'
        )
      )), 0)::float8 AS push_processing_seconds
    FROM push_outbox_events AS push
  `;
  const mediaRows = await sql`
    SELECT
      COUNT(*) FILTER (
        WHERE media.state = 'pending'
          AND media.next_attempt_at <= CURRENT_TIMESTAMP
      )::int AS media_due_count,
      COALESCE(EXTRACT(EPOCH FROM (
        CURRENT_TIMESTAMP - MIN(media.next_attempt_at) FILTER (
          WHERE media.state = 'pending'
            AND media.next_attempt_at <= CURRENT_TIMESTAMP
        )
      )), 0)::float8 AS media_oldest_due_seconds,
      COALESCE(MAX(media.attempt_count) FILTER (
        WHERE media.state IN ('pending', 'processing')
      ), 0)::int AS media_max_attempt_count,
      COALESCE(EXTRACT(EPOCH FROM (
        CURRENT_TIMESTAMP - MIN(media.updated_at) FILTER (
          WHERE media.state = 'processing'
        )
      )), 0)::float8 AS media_processing_seconds
    FROM media_deletion_jobs AS media
  `;
  const push = rows[0] ?? {};
  const media = mediaRows[0] ?? {};
  return {
    pushDueCount: numberValue(push.push_due_count),
    pushOldestDueSeconds: roundedSeconds(push.push_oldest_due_seconds),
    pushFailedCount: numberValue(push.push_failed_count),
    pushProcessingSeconds: roundedSeconds(push.push_processing_seconds),
    mediaDueCount: numberValue(media.media_due_count),
    mediaOldestDueSeconds: roundedSeconds(media.media_oldest_due_seconds),
    mediaMaxAttemptCount: numberValue(media.media_max_attempt_count),
    mediaProcessingSeconds: roundedSeconds(media.media_processing_seconds)
  };
}

async function main() {
  const databaseUrl = process.env.DATABASE_URL;
  if (databaseUrl === undefined || databaseUrl.length === 0) {
    throw new Error("DATABASE_URL is required");
  }
  const sql = postgres(databaseUrl, {
    max: 1,
    connect_timeout: 5,
    idle_timeout: 2
  });
  try {
    const result = evaluateOperationalHealth(
      await queryOperationalSnapshot(sql),
      parseOperationalThresholds()
    );
    process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
    if (!result.ok) process.exitCode = 1;
  } finally {
    await sql.end();
  }
}

function parseNonnegativeInteger(value, name, fallback) {
  if (value === undefined || value.length === 0) return fallback;
  if (!/^\d+$/.test(value)) {
    throw new Error(`${name} must be a nonnegative integer`);
  }
  const parsed = Number(value);
  if (!Number.isSafeInteger(parsed)) {
    throw new Error(`${name} is outside the supported range`);
  }
  return parsed;
}

function numberValue(value) {
  const number = Number(value ?? 0);
  return Number.isFinite(number) ? number : 0;
}

function roundedSeconds(value) {
  return Math.max(0, Math.round(numberValue(value)));
}

const entrypoint = process.argv[1];
if (
  entrypoint !== undefined &&
  pathToFileURL(resolve(entrypoint)).href === import.meta.url
) {
  main().catch((error) => {
    process.stderr.write(`${error instanceof Error ? error.message : error}\n`);
    process.exitCode = 1;
  });
}
