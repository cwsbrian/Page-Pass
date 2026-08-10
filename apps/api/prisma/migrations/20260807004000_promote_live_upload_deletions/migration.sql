INSERT INTO "media_deletion_jobs" (
    "storage_key",
    "state",
    "attempt_count",
    "continuous_verification",
    "next_attempt_at",
    "last_error",
    "completed_at",
    "created_at",
    "updated_at"
)
SELECT
    media."storage_key",
    'pending',
    0,
    true,
    CASE
      WHEN media."completed_at" IS NOT NULL THEN CURRENT_TIMESTAMP
      ELSE GREATEST(
        CURRENT_TIMESTAMP,
        media."upload_expires_at" + INTERVAL '1 minute'
      )
    END,
    NULL,
    NULL,
    CURRENT_TIMESTAMP,
    CURRENT_TIMESTAMP
FROM "media_objects" AS media
WHERE media."upload_expires_at" IS NOT NULL
  AND (
    media."deleted_at" IS NOT NULL
    OR media."upload_status" = 'failed'
  )
ON CONFLICT ("storage_key") DO UPDATE
SET
    "state" = 'pending',
    "attempt_count" = 0,
    "continuous_verification" = true,
    "next_attempt_at" = LEAST(
        "media_deletion_jobs"."next_attempt_at",
        EXCLUDED."next_attempt_at"
    ),
    "last_error" = NULL,
    "completed_at" = NULL,
    "updated_at" = CURRENT_TIMESTAMP;
