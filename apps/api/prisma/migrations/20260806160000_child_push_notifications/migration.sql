CREATE TABLE "child_push_devices" (
    "id" UUID NOT NULL DEFAULT gen_random_uuid(),
    "child_profile_id" UUID NOT NULL,
    "device_id" UUID NOT NULL,
    "token_ciphertext" BYTEA NOT NULL,
    "token_digest" BYTEA NOT NULL,
    "environment" TEXT NOT NULL,
    "app_version" TEXT NOT NULL,
    "app_build" TEXT NOT NULL,
    "last_seen_at" TIMESTAMPTZ(6) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "revoked_at" TIMESTAMPTZ(6),
    "created_at" TIMESTAMPTZ(6) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updated_at" TIMESTAMPTZ(6) NOT NULL,

    CONSTRAINT "child_push_devices_pkey" PRIMARY KEY ("id"),
    CONSTRAINT "child_push_devices_environment_check"
        CHECK ("environment" IN ('sandbox', 'production'))
);

CREATE UNIQUE INDEX "child_push_devices_device_id_key"
    ON "child_push_devices"("device_id");

CREATE UNIQUE INDEX "child_push_devices_token_digest_key"
    ON "child_push_devices"("token_digest");

CREATE INDEX "child_push_devices_child_active_idx"
    ON "child_push_devices"("child_profile_id", "revoked_at");

ALTER TABLE "child_push_devices"
    ADD CONSTRAINT "child_push_devices_child_profile_id_fkey"
    FOREIGN KEY ("child_profile_id") REFERENCES "child_profiles"("id")
    ON DELETE NO ACTION ON UPDATE NO ACTION;

ALTER TABLE "child_push_devices"
    ADD CONSTRAINT "child_push_devices_device_id_fkey"
    FOREIGN KEY ("device_id") REFERENCES "devices"("id")
    ON DELETE NO ACTION ON UPDATE NO ACTION;
