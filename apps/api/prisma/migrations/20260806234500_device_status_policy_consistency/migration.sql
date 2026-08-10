UPDATE "device_status_reports"
SET
    "control_status" = 'unknown',
    "policy_application_result" = NULL,
    "policy_application_policy_version" = NULL,
    "policy_applied_at" = NULL
WHERE
    (
        "control_status" IN ('policy_applied', 'unlocked_for_session')
        AND (
            "policy_application_result" IS DISTINCT FROM 'applied'
            OR "policy_application_policy_version" IS DISTINCT FROM
                "last_applied_policy_version"
        )
    )
    OR (
        "control_status" = 'policy_application_failed'
        AND (
            "policy_application_result" IS DISTINCT FROM 'failed'
            OR "policy_application_policy_version" IS DISTINCT FROM
                "last_applied_policy_version"
        )
    )
    OR (
        "control_status" = 'unknown'
        AND "policy_application_result" IS NOT NULL
    );

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
                AND "policy_application_policy_version" =
                    "last_applied_policy_version"
            )
        );
