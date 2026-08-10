ALTER TABLE "media_objects"
    ADD COLUMN "upload_expires_at" TIMESTAMPTZ(6);

UPDATE "media_objects"
SET "upload_expires_at" = "created_at" + INTERVAL '15 minutes'
WHERE "upload_status" = 'pending' AND "upload_expires_at" IS NULL;

ALTER TABLE "media_objects"
    ALTER COLUMN "upload_expires_at"
    SET DEFAULT (CURRENT_TIMESTAMP + INTERVAL '15 minutes');

ALTER TABLE "media_objects"
    ADD CONSTRAINT "media_objects_pending_expiry_check"
    CHECK ("upload_status" <> 'pending' OR "upload_expires_at" IS NOT NULL);
