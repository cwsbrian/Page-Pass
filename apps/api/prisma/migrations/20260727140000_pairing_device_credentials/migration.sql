-- Preserve the spike-era pairing model while introducing the product pairing
-- lifecycle against child_profiles and devices.
ALTER TABLE "pairing_sessions" RENAME TO "legacy_pairing_sessions";

ALTER INDEX "pairing_sessions_pkey"
    RENAME TO "legacy_pairing_sessions_pkey";
ALTER INDEX "pairing_sessions_qr_token_hash_key"
    RENAME TO "legacy_pairing_sessions_qr_token_hash_key";
ALTER INDEX "pairing_sessions_numeric_code_hash_key"
    RENAME TO "legacy_pairing_sessions_numeric_code_hash_key";
ALTER TABLE "legacy_pairing_sessions"
    RENAME CONSTRAINT "pairing_sessions_child_profile_id_fkey"
    TO "legacy_pairing_sessions_child_profile_id_fkey";

-- Product pairing codes use 900000-999999. Invalidate the short-lived legacy
-- sessions created before that namespace split so a code can never be
-- interpreted against both tables.
UPDATE "legacy_pairing_sessions"
SET "consumed_at" = CURRENT_TIMESTAMP
WHERE "consumed_at" IS NULL;

CREATE TABLE "pairing_sessions" (
    "id" UUID NOT NULL DEFAULT gen_random_uuid(),
    "child_profile_id" UUID NOT NULL,
    "created_by_user_id" TEXT NOT NULL,
    "purpose" TEXT NOT NULL,
    "replaces_device_id" UUID,
    "qr_token_digest" BYTEA NOT NULL,
    "numeric_code_digest" BYTEA NOT NULL,
    "expires_at" TIMESTAMPTZ(6) NOT NULL,
    "invalidated_at" TIMESTAMPTZ(6),
    "consumed_at" TIMESTAMPTZ(6),
    "consumed_by_device_id" UUID,
    "created_at" TIMESTAMPTZ(6) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "pairing_sessions_pkey" PRIMARY KEY ("id"),
    CONSTRAINT "pairing_sessions_purpose_known"
        CHECK ("purpose" IN ('add_device', 'replace_device')),
    CONSTRAINT "pairing_sessions_qr_digest_length"
        CHECK (octet_length("qr_token_digest") = 32),
    CONSTRAINT "pairing_sessions_code_digest_length"
        CHECK (octet_length("numeric_code_digest") = 32),
    CONSTRAINT "pairing_sessions_consumption_consistent"
        CHECK (
            ("consumed_at" IS NULL AND "consumed_by_device_id" IS NULL)
            OR ("consumed_at" IS NOT NULL AND "consumed_by_device_id" IS NOT NULL)
        )
);

CREATE TABLE "device_credentials" (
    "id" UUID NOT NULL DEFAULT gen_random_uuid(),
    "device_id" UUID NOT NULL,
    "token_digest" BYTEA NOT NULL,
    "expires_at" TIMESTAMPTZ(6),
    "revoked_at" TIMESTAMPTZ(6),
    "last_used_at" TIMESTAMPTZ(6),
    "created_at" TIMESTAMPTZ(6) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "device_credentials_pkey" PRIMARY KEY ("id"),
    CONSTRAINT "device_credentials_token_digest_length"
        CHECK (octet_length("token_digest") = 32)
);

CREATE UNIQUE INDEX "pairing_sessions_qr_token_digest_key"
    ON "pairing_sessions"("qr_token_digest");
CREATE UNIQUE INDEX "pairing_sessions_open_numeric_code_digest_key"
    ON "pairing_sessions"("numeric_code_digest")
    WHERE "invalidated_at" IS NULL AND "consumed_at" IS NULL;
CREATE INDEX "pairing_sessions_child_open_idx"
    ON "pairing_sessions"("child_profile_id", "expires_at");
CREATE UNIQUE INDEX "pairing_sessions_one_open_per_child"
    ON "pairing_sessions"("child_profile_id")
    WHERE "invalidated_at" IS NULL AND "consumed_at" IS NULL;

CREATE UNIQUE INDEX "device_credentials_token_digest_key"
    ON "device_credentials"("token_digest");
CREATE INDEX "device_credentials_device_idx"
    ON "device_credentials"("device_id", "revoked_at");
CREATE UNIQUE INDEX "device_credentials_one_active_per_device"
    ON "device_credentials"("device_id")
    WHERE "revoked_at" IS NULL;

ALTER TABLE "pairing_sessions"
    ADD CONSTRAINT "pairing_sessions_child_profile_id_fkey"
    FOREIGN KEY ("child_profile_id") REFERENCES "child_profiles"("id")
    ON DELETE NO ACTION ON UPDATE NO ACTION;

ALTER TABLE "device_credentials"
    ADD CONSTRAINT "device_credentials_device_id_fkey"
    FOREIGN KEY ("device_id") REFERENCES "devices"("id")
    ON DELETE NO ACTION ON UPDATE NO ACTION;
