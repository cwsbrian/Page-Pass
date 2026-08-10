CREATE TABLE "media_deletion_jobs" (
    "id" UUID NOT NULL DEFAULT gen_random_uuid(),
    "storage_key" TEXT NOT NULL,
    "state" TEXT NOT NULL DEFAULT 'pending',
    "attempt_count" INTEGER NOT NULL DEFAULT 0,
    "next_attempt_at" TIMESTAMPTZ(6) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "last_error" TEXT,
    "completed_at" TIMESTAMPTZ(6),
    "created_at" TIMESTAMPTZ(6) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updated_at" TIMESTAMPTZ(6) NOT NULL,

    CONSTRAINT "media_deletion_jobs_pkey" PRIMARY KEY ("id"),
    CONSTRAINT "media_deletion_jobs_state_check"
        CHECK ("state" IN ('pending', 'processing', 'completed'))
);

CREATE UNIQUE INDEX "media_deletion_jobs_storage_key_key"
    ON "media_deletion_jobs"("storage_key");

CREATE INDEX "media_deletion_jobs_pending_idx"
    ON "media_deletion_jobs"("state", "next_attempt_at");
