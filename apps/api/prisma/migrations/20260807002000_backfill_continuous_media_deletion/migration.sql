UPDATE "media_deletion_jobs" AS job
SET
    "state" = 'pending',
    "attempt_count" = 0,
    "continuous_verification" = true,
    "next_attempt_at" = GREATEST(
        job."next_attempt_at",
        media."upload_expires_at" + INTERVAL '1 minute'
    ),
    "last_error" = NULL,
    "completed_at" = NULL,
    "updated_at" = CURRENT_TIMESTAMP
FROM "media_objects" AS media
WHERE job."storage_key" = media."storage_key"
  AND media."completed_at" IS NULL
  AND media."upload_expires_at" IS NOT NULL;
