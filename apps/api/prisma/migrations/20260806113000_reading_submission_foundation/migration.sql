CREATE TABLE "media_objects" (
    "id" UUID NOT NULL DEFAULT gen_random_uuid(),
    "child_profile_id" UUID NOT NULL,
    "uploaded_by_device_id" UUID,
    "uploaded_by_user_id" TEXT,
    "kind" TEXT NOT NULL,
    "storage_key" TEXT NOT NULL,
    "content_type" TEXT NOT NULL,
    "byte_size" BIGINT NOT NULL,
    "sha256" BYTEA NOT NULL,
    "upload_status" TEXT NOT NULL DEFAULT 'pending',
    "completed_at" TIMESTAMPTZ(6),
    "deleted_at" TIMESTAMPTZ(6),
    "created_at" TIMESTAMPTZ(6) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updated_at" TIMESTAMPTZ(6) NOT NULL,

    CONSTRAINT "media_objects_pkey" PRIMARY KEY ("id"),
    CONSTRAINT "media_objects_uploader_check"
        CHECK (num_nonnulls("uploaded_by_device_id", "uploaded_by_user_id") = 1),
    CONSTRAINT "media_objects_kind_check"
        CHECK ("kind" IN ('handwritten_page', 'book_cover', 'profile_image', 'thumbnail')),
    CONSTRAINT "media_objects_content_type_check"
        CHECK ("content_type" IN ('image/jpeg', 'image/png', 'image/heic', 'image/heif')),
    CONSTRAINT "media_objects_byte_size_check"
        CHECK ("byte_size" > 0 AND "byte_size" <= 26214400),
    CONSTRAINT "media_objects_sha256_check"
        CHECK (octet_length("sha256") = 32),
    CONSTRAINT "media_objects_upload_status_check"
        CHECK ("upload_status" IN ('pending', 'uploaded', 'failed', 'deleted'))
);

CREATE TABLE "reading_submissions" (
    "id" UUID NOT NULL DEFAULT gen_random_uuid(),
    "child_profile_id" UUID NOT NULL,
    "created_by_device_id" UUID NOT NULL,
    "supersedes_submission_id" UUID,
    "version" BIGINT NOT NULL DEFAULT 1,
    "revision" INTEGER NOT NULL DEFAULT 1,
    "status" TEXT NOT NULL DEFAULT 'draft',
    "processing_status" TEXT NOT NULL DEFAULT 'idle',
    "book_title" TEXT,
    "author" TEXT,
    "cover_media_id" UUID,
    "corrected_ocr_text" TEXT,
    "submitted_at" TIMESTAMPTZ(6),
    "reviewed_at" TIMESTAMPTZ(6),
    "created_at" TIMESTAMPTZ(6) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updated_at" TIMESTAMPTZ(6) NOT NULL,

    CONSTRAINT "reading_submissions_pkey" PRIMARY KEY ("id"),
    CONSTRAINT "reading_submissions_version_check" CHECK ("version" > 0),
    CONSTRAINT "reading_submissions_revision_check" CHECK ("revision" > 0),
    CONSTRAINT "reading_submissions_status_check"
        CHECK ("status" IN ('draft', 'pending', 'changes_requested', 'approved', 'rejected')),
    CONSTRAINT "reading_submissions_processing_status_check"
        CHECK ("processing_status" IN ('idle', 'processing', 'failed')),
    CONSTRAINT "reading_submissions_supersedes_check"
        CHECK ("supersedes_submission_id" IS NULL OR "supersedes_submission_id" <> "id")
);

CREATE TABLE "reading_evidence" (
    "id" UUID NOT NULL DEFAULT gen_random_uuid(),
    "child_profile_id" UUID NOT NULL,
    "submission_id" UUID NOT NULL,
    "original_media_id" UUID NOT NULL,
    "thumbnail_media_id" UUID,
    "page_order" INTEGER NOT NULL,
    "raw_ocr_text" TEXT,
    "ocr_language_codes" TEXT[] NOT NULL DEFAULT ARRAY[]::TEXT[],
    "ocr_revision" INTEGER NOT NULL DEFAULT 0,
    "vision_revision" INTEGER,
    "ocr_status" TEXT NOT NULL DEFAULT 'pending',
    "created_at" TIMESTAMPTZ(6) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updated_at" TIMESTAMPTZ(6) NOT NULL,

    CONSTRAINT "reading_evidence_pkey" PRIMARY KEY ("id"),
    CONSTRAINT "reading_evidence_page_order_check" CHECK ("page_order" >= 0),
    CONSTRAINT "reading_evidence_ocr_revision_check" CHECK ("ocr_revision" >= 0),
    CONSTRAINT "reading_evidence_vision_revision_check"
        CHECK ("vision_revision" IS NULL OR "vision_revision" > 0),
    CONSTRAINT "reading_evidence_ocr_status_check"
        CHECK ("ocr_status" IN ('pending', 'succeeded', 'low_confidence', 'failed')),
    CONSTRAINT "reading_evidence_ocr_attempt_check"
        CHECK (
            ("ocr_status" = 'pending' AND "ocr_revision" = 0 AND "vision_revision" IS NULL)
            OR
            ("ocr_status" <> 'pending' AND "ocr_revision" > 0 AND "vision_revision" IS NOT NULL)
        )
);

CREATE TABLE "submission_reviews" (
    "id" UUID NOT NULL DEFAULT gen_random_uuid(),
    "child_profile_id" UUID NOT NULL,
    "submission_id" UUID NOT NULL,
    "submission_revision" INTEGER NOT NULL,
    "decision" TEXT NOT NULL,
    "comment" TEXT,
    "reward_seconds" INTEGER NOT NULL DEFAULT 0,
    "reviewed_by_user_id" TEXT NOT NULL,
    "idempotency_key" TEXT NOT NULL,
    "request_fingerprint" TEXT NOT NULL,
    "created_at" TIMESTAMPTZ(6) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "submission_reviews_pkey" PRIMARY KEY ("id"),
    CONSTRAINT "submission_reviews_revision_check" CHECK ("submission_revision" > 0),
    CONSTRAINT "submission_reviews_decision_check"
        CHECK ("decision" IN ('approved', 'changes_requested', 'rejected')),
    CONSTRAINT "submission_reviews_reward_check"
        CHECK (
            ("decision" = 'approved' AND "reward_seconds" > 0)
            OR
            (
                "decision" IN ('changes_requested', 'rejected')
                AND "reward_seconds" = 0
                AND length(btrim(COALESCE("comment", ''))) > 0
            )
        )
);

CREATE UNIQUE INDEX "media_objects_storage_key_key"
    ON "media_objects"("storage_key");

CREATE INDEX "media_objects_child_status_idx"
    ON "media_objects"("child_profile_id", "upload_status", "created_at");

CREATE INDEX "reading_submissions_child_status_idx"
    ON "reading_submissions"("child_profile_id", "status", "updated_at" DESC);

CREATE UNIQUE INDEX "reading_evidence_submission_page_key"
    ON "reading_evidence"("submission_id", "page_order");

CREATE INDEX "reading_evidence_child_submission_idx"
    ON "reading_evidence"("child_profile_id", "submission_id");

CREATE UNIQUE INDEX "submission_reviews_submission_revision_key"
    ON "submission_reviews"("submission_id", "submission_revision");

CREATE UNIQUE INDEX "submission_reviews_user_idempotency_key"
    ON "submission_reviews"("reviewed_by_user_id", "idempotency_key");

CREATE INDEX "submission_reviews_child_created_idx"
    ON "submission_reviews"("child_profile_id", "created_at" DESC);

ALTER TABLE "media_objects"
    ADD CONSTRAINT "media_objects_child_profile_id_fkey"
    FOREIGN KEY ("child_profile_id") REFERENCES "child_profiles"("id")
    ON DELETE NO ACTION ON UPDATE NO ACTION;

ALTER TABLE "reading_submissions"
    ADD CONSTRAINT "reading_submissions_child_profile_id_fkey"
    FOREIGN KEY ("child_profile_id") REFERENCES "child_profiles"("id")
    ON DELETE NO ACTION ON UPDATE NO ACTION;

ALTER TABLE "reading_evidence"
    ADD CONSTRAINT "reading_evidence_child_profile_id_fkey"
    FOREIGN KEY ("child_profile_id") REFERENCES "child_profiles"("id")
    ON DELETE NO ACTION ON UPDATE NO ACTION;

ALTER TABLE "reading_evidence"
    ADD CONSTRAINT "reading_evidence_submission_id_fkey"
    FOREIGN KEY ("submission_id") REFERENCES "reading_submissions"("id")
    ON DELETE NO ACTION ON UPDATE NO ACTION;

ALTER TABLE "submission_reviews"
    ADD CONSTRAINT "submission_reviews_child_profile_id_fkey"
    FOREIGN KEY ("child_profile_id") REFERENCES "child_profiles"("id")
    ON DELETE NO ACTION ON UPDATE NO ACTION;

ALTER TABLE "submission_reviews"
    ADD CONSTRAINT "submission_reviews_submission_id_fkey"
    FOREIGN KEY ("submission_id") REFERENCES "reading_submissions"("id")
    ON DELETE NO ACTION ON UPDATE NO ACTION;
