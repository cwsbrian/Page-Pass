ALTER TABLE "device_status_reports"
    DROP CONSTRAINT "device_status_reports_policy_evidence_matches_control";

ALTER TABLE "device_status_reports"
    ADD CONSTRAINT "device_status_reports_policy_evidence_matches_control"
        CHECK (
            (
                "control_status" = 'unknown'
                AND "policy_application_result" IS NULL
            )
            OR (
                "control_status" IN ('policy_applied', 'unlocked_for_session')
                AND "policy_application_result" = 'applied'
                AND "policy_application_policy_version" =
                    "last_applied_policy_version"
            )
            OR (
                "control_status" = 'policy_application_failed'
                AND "policy_application_result" = 'failed'
            )
        );
