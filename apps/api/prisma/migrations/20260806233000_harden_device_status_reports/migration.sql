ALTER TABLE "device_status_reports"
    DROP CONSTRAINT "device_status_reports_shield_known",
    DROP CONSTRAINT "device_status_reports_lock_verification_consistent";

ALTER TABLE "device_status_reports"
    RENAME COLUMN "shield_status" TO "control_status";
ALTER TABLE "device_status_reports"
    RENAME COLUMN "lock_verification_result" TO "policy_application_result";
ALTER TABLE "device_status_reports"
    RENAME COLUMN "lock_verification_policy_version" TO "policy_application_policy_version";
ALTER TABLE "device_status_reports"
    RENAME COLUMN "lock_verified_at" TO "policy_applied_at";

UPDATE "device_status_reports"
SET
    "control_status" = CASE "control_status"
        WHEN 'locked' THEN 'policy_applied'
        WHEN 'verification_failed' THEN 'policy_application_failed'
        ELSE "control_status"
    END,
    "policy_application_result" = CASE "policy_application_result"
        WHEN 'passed' THEN 'applied'
        ELSE "policy_application_result"
    END;

ALTER TABLE "device_status_reports"
    ADD COLUMN "request_fingerprint" TEXT;

UPDATE "device_status_reports"
SET "request_fingerprint" = md5(concat_ws(
    '|',
    "id"::text,
    "device_id"::text,
    "observed_at"::text,
    "received_at"::text
));

ALTER TABLE "device_status_reports"
    ALTER COLUMN "request_fingerprint" SET NOT NULL;

ALTER TABLE "device_status_reports"
    ADD CONSTRAINT "device_status_reports_control_status_known"
        CHECK ("control_status" IN (
            'unknown',
            'policy_applied',
            'unlocked_for_session',
            'policy_application_failed'
        )),
    ADD CONSTRAINT "device_status_reports_policy_application_consistent"
        CHECK (
            (
                "policy_application_result" IS NULL
                AND "policy_application_policy_version" IS NULL
                AND "policy_applied_at" IS NULL
            )
            OR (
                "policy_application_result" IN ('applied', 'failed')
                AND "policy_application_policy_version" >= 0
                AND "policy_applied_at" IS NOT NULL
                AND "policy_applied_at" <= "observed_at" + INTERVAL '30 seconds'
            )
        );
