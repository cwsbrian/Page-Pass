UPDATE "media_objects"
SET "upload_expires_at" = "created_at" + INTERVAL '15 minutes'
WHERE "completed_at" IS NULL
  AND "upload_expires_at" IS NULL;

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
    GREATEST(
        CURRENT_TIMESTAMP,
        media."upload_expires_at" + INTERVAL '1 minute'
    ),
    NULL,
    NULL,
    CURRENT_TIMESTAMP,
    CURRENT_TIMESTAMP
FROM "media_objects" AS media
JOIN "child_profiles" AS child
  ON child."id" = media."child_profile_id"
WHERE media."completed_at" IS NULL
  AND (
    media."deleted_at" IS NOT NULL
    OR media."upload_status" = 'failed'
    OR child."status" = 'archived'
  )
ON CONFLICT ("storage_key") DO UPDATE
SET
    "state" = 'pending',
    "attempt_count" = 0,
    "continuous_verification" = true,
    "next_attempt_at" = GREATEST(
        "media_deletion_jobs"."next_attempt_at",
        EXCLUDED."next_attempt_at"
    ),
    "last_error" = NULL,
    "completed_at" = NULL,
    "updated_at" = CURRENT_TIMESTAMP;
