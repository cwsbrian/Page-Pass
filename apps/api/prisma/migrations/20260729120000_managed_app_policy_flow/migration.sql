CREATE TABLE "managed_apps" (
    "id" UUID NOT NULL DEFAULT gen_random_uuid(),
    "child_profile_id" UUID NOT NULL,
    "source_device_id" UUID NOT NULL,
    "client_app_id" TEXT NOT NULL,
    "token_ciphertext" BYTEA NOT NULL,
    "token_digest" BYTEA NOT NULL,
    "token_format_version" INTEGER NOT NULL,
    "current_policy" TEXT NOT NULL DEFAULT 'blocked',
    "current_policy_version" BIGINT NOT NULL DEFAULT 0,
    "registered_at" TIMESTAMPTZ(6) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "archived_at" TIMESTAMPTZ(6),
    "updated_at" TIMESTAMPTZ(6) NOT NULL,
    CONSTRAINT "managed_apps_pkey" PRIMARY KEY ("id"),
    CONSTRAINT "managed_apps_policy_check"
      CHECK ("current_policy" IN ('blocked', 'earned_time', 'always_allowed')),
    CONSTRAINT "managed_apps_token_format_check"
      CHECK ("token_format_version" > 0)
);

CREATE TABLE "app_requests" (
    "id" UUID NOT NULL DEFAULT gen_random_uuid(),
    "child_profile_id" UUID NOT NULL,
    "managed_app_id" UUID NOT NULL,
    "requested_by_device_id" UUID NOT NULL,
    "message" TEXT,
    "status" TEXT NOT NULL DEFAULT 'pending',
    "request_version" BIGINT NOT NULL DEFAULT 1,
    "request_idempotency_key" TEXT NOT NULL,
    "request_fingerprint" TEXT NOT NULL,
    "previous_policy" TEXT NOT NULL,
    "decision" TEXT,
    "decided_by_user_id" TEXT,
    "decision_idempotency_key" TEXT,
    "decision_fingerprint" TEXT,
    "requested_at" TIMESTAMPTZ(6) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "decided_at" TIMESTAMPTZ(6),
    "updated_at" TIMESTAMPTZ(6) NOT NULL,
    CONSTRAINT "app_requests_pkey" PRIMARY KEY ("id"),
    CONSTRAINT "app_requests_status_check"
      CHECK ("status" IN ('pending', 'decided')),
    CONSTRAINT "app_requests_policy_check"
      CHECK ("previous_policy" IN ('blocked', 'earned_time', 'always_allowed')),
    CONSTRAINT "app_requests_decision_check"
      CHECK ("decision" IS NULL OR "decision" IN ('approved', 'denied'))
);

CREATE TABLE "child_policy_versions" (
    "id" UUID NOT NULL DEFAULT gen_random_uuid(),
    "child_profile_id" UUID NOT NULL,
    "version" BIGINT NOT NULL,
    "source" TEXT NOT NULL,
    "actor_user_id" TEXT,
    "idempotency_key" TEXT NOT NULL,
    "request_fingerprint" TEXT NOT NULL,
    "created_at" TIMESTAMPTZ(6) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT "child_policy_versions_pkey" PRIMARY KEY ("id"),
    CONSTRAINT "child_policy_versions_version_check" CHECK ("version" > 0)
);

CREATE TABLE "app_policy_changes" (
    "id" UUID NOT NULL DEFAULT gen_random_uuid(),
    "child_profile_id" UUID NOT NULL,
    "policy_version_id" UUID NOT NULL,
    "managed_app_id" UUID NOT NULL,
    "source_request_id" UUID,
    "from_policy" TEXT,
    "to_policy" TEXT NOT NULL,
    "changed_by_user_id" TEXT,
    "created_at" TIMESTAMPTZ(6) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT "app_policy_changes_pkey" PRIMARY KEY ("id"),
    CONSTRAINT "app_policy_changes_from_policy_check"
      CHECK ("from_policy" IS NULL OR "from_policy" IN ('blocked', 'earned_time', 'always_allowed')),
    CONSTRAINT "app_policy_changes_to_policy_check"
      CHECK ("to_policy" IN ('blocked', 'earned_time', 'always_allowed'))
);

CREATE TABLE "policy_application_acks" (
    "id" UUID NOT NULL DEFAULT gen_random_uuid(),
    "child_profile_id" UUID NOT NULL,
    "policy_version" BIGINT NOT NULL,
    "device_id" UUID NOT NULL,
    "result" TEXT NOT NULL,
    "failure_reason" TEXT,
    "applied_at" TIMESTAMPTZ(6) NOT NULL,
    "reported_at" TIMESTAMPTZ(6) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT "policy_application_acks_pkey" PRIMARY KEY ("id"),
    CONSTRAINT "policy_application_acks_result_check"
      CHECK ("result" IN ('applied', 'failed')),
    CONSTRAINT "policy_application_acks_failure_check"
      CHECK (
        ("result" = 'applied' AND "failure_reason" IS NULL) OR
        ("result" = 'failed' AND "failure_reason" IS NOT NULL)
      )
);

CREATE UNIQUE INDEX "managed_apps_device_client_key"
  ON "managed_apps"("source_device_id", "client_app_id");
CREATE UNIQUE INDEX "managed_apps_device_token_key"
  ON "managed_apps"("source_device_id", "token_digest");
CREATE INDEX "managed_apps_child_policy_idx"
  ON "managed_apps"("child_profile_id", "current_policy", "archived_at");
CREATE UNIQUE INDEX "app_requests_child_request_idem_key"
  ON "app_requests"("child_profile_id", "request_idempotency_key");
CREATE UNIQUE INDEX "app_requests_one_pending_per_app_key"
  ON "app_requests"("managed_app_id") WHERE "status" = 'pending';
CREATE UNIQUE INDEX "app_requests_child_decision_idem_key"
  ON "app_requests"("child_profile_id", "decision_idempotency_key")
  WHERE "decision_idempotency_key" IS NOT NULL;
CREATE INDEX "app_requests_child_status_idx"
  ON "app_requests"("child_profile_id", "status", "requested_at");
CREATE UNIQUE INDEX "child_policy_versions_child_version_key"
  ON "child_policy_versions"("child_profile_id", "version");
CREATE UNIQUE INDEX "child_policy_versions_child_idempotency_key"
  ON "child_policy_versions"("child_profile_id", "idempotency_key");
CREATE INDEX "app_policy_changes_child_created_idx"
  ON "app_policy_changes"("child_profile_id", "created_at");
CREATE INDEX "app_policy_changes_version_idx"
  ON "app_policy_changes"("policy_version_id");
CREATE UNIQUE INDEX "policy_application_acks_device_version_key"
  ON "policy_application_acks"("device_id", "policy_version");
CREATE INDEX "policy_application_acks_child_version_idx"
  ON "policy_application_acks"("child_profile_id", "policy_version");

ALTER TABLE "managed_apps"
  ADD CONSTRAINT "managed_apps_child_profile_id_fkey"
  FOREIGN KEY ("child_profile_id") REFERENCES "child_profiles"("id")
  ON DELETE NO ACTION ON UPDATE NO ACTION;
ALTER TABLE "app_requests"
  ADD CONSTRAINT "app_requests_child_profile_id_fkey"
  FOREIGN KEY ("child_profile_id") REFERENCES "child_profiles"("id")
  ON DELETE NO ACTION ON UPDATE NO ACTION;
ALTER TABLE "child_policy_versions"
  ADD CONSTRAINT "child_policy_versions_child_profile_id_fkey"
  FOREIGN KEY ("child_profile_id") REFERENCES "child_profiles"("id")
  ON DELETE NO ACTION ON UPDATE NO ACTION;
ALTER TABLE "policy_application_acks"
  ADD CONSTRAINT "policy_application_acks_child_profile_id_fkey"
  FOREIGN KEY ("child_profile_id") REFERENCES "child_profiles"("id")
  ON DELETE NO ACTION ON UPDATE NO ACTION;
