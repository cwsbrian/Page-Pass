CREATE TABLE "parent_push_devices" (
    "id" UUID NOT NULL DEFAULT gen_random_uuid(),
    "user_id" TEXT NOT NULL,
    "installation_id" TEXT NOT NULL,
    "token_ciphertext" BYTEA NOT NULL,
    "token_digest" BYTEA NOT NULL,
    "environment" TEXT NOT NULL,
    "app_version" TEXT NOT NULL,
    "app_build" TEXT NOT NULL,
    "last_seen_at" TIMESTAMPTZ(6) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "revoked_at" TIMESTAMPTZ(6),
    "created_at" TIMESTAMPTZ(6) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updated_at" TIMESTAMPTZ(6) NOT NULL,

    CONSTRAINT "parent_push_devices_pkey" PRIMARY KEY ("id"),
    CONSTRAINT "parent_push_devices_environment_check"
        CHECK ("environment" IN ('sandbox', 'production'))
);

CREATE TABLE "push_outbox_events" (
    "id" UUID NOT NULL DEFAULT gen_random_uuid(),
    "family_id" UUID NOT NULL,
    "child_profile_id" UUID NOT NULL,
    "event_type" TEXT NOT NULL,
    "payload" JSONB NOT NULL,
    "state" TEXT NOT NULL DEFAULT 'pending',
    "attempt_count" INTEGER NOT NULL DEFAULT 0,
    "next_attempt_at" TIMESTAMPTZ(6) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "last_error" TEXT,
    "sent_at" TIMESTAMPTZ(6),
    "created_at" TIMESTAMPTZ(6) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updated_at" TIMESTAMPTZ(6) NOT NULL,

    CONSTRAINT "push_outbox_events_pkey" PRIMARY KEY ("id"),
    CONSTRAINT "push_outbox_events_state_check"
        CHECK ("state" IN ('pending', 'processing', 'sent')),
    CONSTRAINT "push_outbox_events_attempt_count_check"
        CHECK ("attempt_count" >= 0)
);

CREATE UNIQUE INDEX "parent_push_devices_token_digest_key"
    ON "parent_push_devices"("token_digest");

CREATE UNIQUE INDEX "parent_push_devices_user_installation_key"
    ON "parent_push_devices"("user_id", "installation_id");

CREATE INDEX "parent_push_devices_user_active_idx"
    ON "parent_push_devices"("user_id", "revoked_at");

CREATE INDEX "push_outbox_events_pending_idx"
    ON "push_outbox_events"("state", "next_attempt_at");

ALTER TABLE "parent_push_devices"
    ADD CONSTRAINT "parent_push_devices_user_id_fkey"
    FOREIGN KEY ("user_id") REFERENCES "users"("id")
    ON DELETE CASCADE ON UPDATE CASCADE;
