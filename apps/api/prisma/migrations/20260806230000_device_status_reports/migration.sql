CREATE TABLE "device_status_reports" (
    "id" UUID NOT NULL DEFAULT gen_random_uuid(),
    "device_id" UUID NOT NULL,
    "observed_at" TIMESTAMPTZ(6) NOT NULL,
    "authorization_status" TEXT NOT NULL,
    "managed_app_count" INTEGER NOT NULL DEFAULT 0,
    "shield_status" TEXT NOT NULL,
    "last_applied_policy_version" BIGINT NOT NULL DEFAULT 0,
    "lock_verification_result" TEXT,
    "lock_verification_policy_version" BIGINT,
    "lock_verified_at" TIMESTAMPTZ(6),
    "pending_settlement_count" INTEGER NOT NULL DEFAULT 0,
    "received_at" TIMESTAMPTZ(6) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "device_status_reports_pkey" PRIMARY KEY ("id"),
    CONSTRAINT "device_status_reports_authorization_known"
        CHECK ("authorization_status" IN (
            'not_determined',
            'approved',
            'denied',
            'conflict',
            'restricted',
            'revoked',
            'unavailable'
        )),
    CONSTRAINT "device_status_reports_shield_known"
        CHECK ("shield_status" IN (
            'unknown',
            'locked',
            'unlocked_for_session',
            'verification_failed'
        )),
    CONSTRAINT "device_status_reports_counts_nonnegative"
        CHECK (
            "managed_app_count" >= 0
            AND "pending_settlement_count" >= 0
        ),
    CONSTRAINT "device_status_reports_policy_version_nonnegative"
        CHECK ("last_applied_policy_version" >= 0),
    CONSTRAINT "device_status_reports_lock_verification_consistent"
        CHECK (
            (
                "lock_verification_result" IS NULL
                AND "lock_verification_policy_version" IS NULL
                AND "lock_verified_at" IS NULL
            )
            OR (
                "lock_verification_result" IN ('passed', 'failed')
                AND "lock_verification_policy_version" >= 0
                AND "lock_verified_at" IS NOT NULL
            )
        )
);

CREATE UNIQUE INDEX "device_status_reports_device_observed_key"
    ON "device_status_reports"("device_id", "observed_at");

CREATE INDEX "device_status_reports_latest_idx"
    ON "device_status_reports"("device_id", "observed_at" DESC, "received_at" DESC);

ALTER TABLE "device_status_reports"
    ADD CONSTRAINT "device_status_reports_device_id_fkey"
    FOREIGN KEY ("device_id") REFERENCES "devices"("id")
    ON DELETE NO ACTION ON UPDATE NO ACTION;
