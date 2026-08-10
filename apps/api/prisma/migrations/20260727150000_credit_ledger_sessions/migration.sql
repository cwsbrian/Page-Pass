-- Product credit ledger and the durable projection used by child snapshots.
CREATE TABLE "child_credit_balances" (
    "child_profile_id" UUID NOT NULL,
    "balance_seconds" BIGINT NOT NULL DEFAULT 0,
    "ledger_revision" BIGINT NOT NULL DEFAULT 0,
    "updated_at" TIMESTAMPTZ(6) NOT NULL,

    CONSTRAINT "child_credit_balances_pkey" PRIMARY KEY ("child_profile_id"),
    CONSTRAINT "child_credit_balances_balance_valid"
        CHECK ("balance_seconds" BETWEEN 0 AND 9007199254740991),
    CONSTRAINT "child_credit_balances_revision_valid"
        CHECK ("ledger_revision" BETWEEN 0 AND 9007199254740991)
);

CREATE TABLE "earned_time_sessions" (
    "id" UUID NOT NULL DEFAULT gen_random_uuid(),
    "child_profile_id" UUID NOT NULL,
    "device_id" UUID NOT NULL,
    "local_session_id" TEXT NOT NULL,
    "requested_duration_seconds" INTEGER NOT NULL,
    "balance_before_seconds" BIGINT NOT NULL,
    "balance_after_seconds" BIGINT,
    "started_at" TIMESTAMPTZ(6) NOT NULL,
    "expires_at" TIMESTAMPTZ(6) NOT NULL,
    "state" TEXT NOT NULL,
    "ended_at" TIMESTAMPTZ(6),
    "consumed_seconds" INTEGER,
    "end_reason" TEXT,
    "settlement_idempotency_key" TEXT,
    "request_fingerprint" TEXT NOT NULL,
    "rejection_code" TEXT,
    "prepared_at" TIMESTAMPTZ(6),
    "active_synced_at" TIMESTAMPTZ(6),
    "settled_at" TIMESTAMPTZ(6),
    "created_at" TIMESTAMPTZ(6) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updated_at" TIMESTAMPTZ(6) NOT NULL,

    CONSTRAINT "earned_time_sessions_pkey" PRIMARY KEY ("id"),
    CONSTRAINT "earned_time_sessions_duration_valid"
        CHECK ("requested_duration_seconds" BETWEEN 900 AND 86400),
    CONSTRAINT "earned_time_sessions_balance_before_valid"
        CHECK ("balance_before_seconds" BETWEEN 0 AND 9007199254740991),
    CONSTRAINT "earned_time_sessions_balance_after_valid"
        CHECK (
            "balance_after_seconds" IS NULL
            OR "balance_after_seconds" BETWEEN 0 AND 9007199254740991
        ),
    CONSTRAINT "earned_time_sessions_state_known"
        CHECK ("state" IN (
            'prepared',
            'active',
            'settlement_pending',
            'settled',
            'cancelled',
            'rejected'
        )),
    CONSTRAINT "earned_time_sessions_consumed_valid"
        CHECK (
            "consumed_seconds" IS NULL
            OR "consumed_seconds" BETWEEN 0 AND "requested_duration_seconds"
        ),
    CONSTRAINT "earned_time_sessions_end_reason_known"
        CHECK (
            "end_reason" IS NULL
            OR "end_reason" IN (
                'manual_stop',
                'expired',
                'recovery',
                'activation_failed'
            )
        ),
    CONSTRAINT "earned_time_sessions_settled_complete"
        CHECK (
            "state" <> 'settled'
            OR (
                "ended_at" IS NOT NULL
                AND "consumed_seconds" IS NOT NULL
                AND "balance_after_seconds" IS NOT NULL
                AND "end_reason" IS NOT NULL
                AND "settlement_idempotency_key" IS NOT NULL
                AND "settled_at" IS NOT NULL
            )
        )
);

CREATE TABLE "credit_ledger_entries" (
    "id" UUID NOT NULL DEFAULT gen_random_uuid(),
    "child_profile_id" UUID NOT NULL,
    "ledger_revision" BIGINT NOT NULL,
    "entry_type" TEXT NOT NULL,
    "amount_seconds" BIGINT NOT NULL,
    "balance_after_seconds" BIGINT NOT NULL,
    "actor_user_id" TEXT,
    "earned_time_session_id" UUID,
    "submission_review_id" UUID,
    "reason" TEXT,
    "idempotency_key" TEXT NOT NULL,
    "request_fingerprint" TEXT NOT NULL,
    "created_at" TIMESTAMPTZ(6) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "credit_ledger_entries_pkey" PRIMARY KEY ("id"),
    CONSTRAINT "credit_ledger_entries_type_known"
        CHECK ("entry_type" IN (
            'parent_grant',
            'reading_reward',
            'session_spend',
            'parent_adjustment'
        )),
    CONSTRAINT "credit_ledger_entries_amount_nonzero"
        CHECK ("amount_seconds" <> 0),
    CONSTRAINT "credit_ledger_entries_balance_valid"
        CHECK ("balance_after_seconds" BETWEEN 0 AND 9007199254740991),
    CONSTRAINT "credit_ledger_entries_revision_valid"
        CHECK ("ledger_revision" BETWEEN 1 AND 9007199254740991)
);

-- Keep old application instances safe during a rolling deploy. Any child
-- inserted after this migration receives its projection in the same DB
-- transaction, even before the new application build is live.
CREATE FUNCTION create_child_credit_balance()
RETURNS trigger AS $$
BEGIN
  INSERT INTO "child_credit_balances" (
      "child_profile_id",
      "balance_seconds",
      "ledger_revision",
      "updated_at"
  ) VALUES (
      NEW."id",
      0,
      0,
      CURRENT_TIMESTAMP
  ) ON CONFLICT ("child_profile_id") DO NOTHING;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER "child_profiles_create_credit_balance"
AFTER INSERT ON "child_profiles"
FOR EACH ROW EXECUTE FUNCTION create_child_credit_balance();

INSERT INTO "child_credit_balances" (
    "child_profile_id",
    "balance_seconds",
    "ledger_revision",
    "updated_at"
)
SELECT "id", 0, 0, CURRENT_TIMESTAMP
FROM "child_profiles"
ON CONFLICT ("child_profile_id") DO NOTHING;

CREATE UNIQUE INDEX "earned_time_sessions_child_local_key"
    ON "earned_time_sessions"("child_profile_id", "local_session_id");
CREATE UNIQUE INDEX "earned_time_sessions_child_settlement_key"
    ON "earned_time_sessions"("child_profile_id", "settlement_idempotency_key");
CREATE INDEX "earned_time_sessions_child_state_expiry_idx"
    ON "earned_time_sessions"("child_profile_id", "state", "expires_at");
CREATE UNIQUE INDEX "earned_time_sessions_one_unsettled_per_child"
    ON "earned_time_sessions"("child_profile_id")
    WHERE "state" IN ('prepared', 'active', 'settlement_pending');

CREATE UNIQUE INDEX "credit_ledger_entries_child_revision_key"
    ON "credit_ledger_entries"("child_profile_id", "ledger_revision");
CREATE UNIQUE INDEX "credit_ledger_entries_child_idempotency_key"
    ON "credit_ledger_entries"("child_profile_id", "idempotency_key");
CREATE UNIQUE INDEX "credit_ledger_entries_earned_session_key"
    ON "credit_ledger_entries"("earned_time_session_id");
CREATE UNIQUE INDEX "credit_ledger_entries_submission_review_key"
    ON "credit_ledger_entries"("submission_review_id");
CREATE INDEX "credit_ledger_entries_child_created_idx"
    ON "credit_ledger_entries"("child_profile_id", "created_at");

ALTER TABLE "child_credit_balances"
    ADD CONSTRAINT "child_credit_balances_child_profile_id_fkey"
    FOREIGN KEY ("child_profile_id") REFERENCES "child_profiles"("id")
    ON DELETE NO ACTION ON UPDATE NO ACTION;

ALTER TABLE "earned_time_sessions"
    ADD CONSTRAINT "earned_time_sessions_child_profile_id_fkey"
    FOREIGN KEY ("child_profile_id") REFERENCES "child_profiles"("id")
    ON DELETE NO ACTION ON UPDATE NO ACTION;

ALTER TABLE "earned_time_sessions"
    ADD CONSTRAINT "earned_time_sessions_device_id_fkey"
    FOREIGN KEY ("device_id") REFERENCES "devices"("id")
    ON DELETE NO ACTION ON UPDATE NO ACTION;

ALTER TABLE "credit_ledger_entries"
    ADD CONSTRAINT "credit_ledger_entries_child_profile_id_fkey"
    FOREIGN KEY ("child_profile_id") REFERENCES "child_profiles"("id")
    ON DELETE NO ACTION ON UPDATE NO ACTION;

CREATE FUNCTION reject_credit_ledger_entry_mutation()
RETURNS trigger AS $$
BEGIN
  RAISE EXCEPTION 'credit_ledger_entries is append-only';
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER "credit_ledger_entries_append_only_update"
BEFORE UPDATE ON "credit_ledger_entries"
FOR EACH ROW EXECUTE FUNCTION reject_credit_ledger_entry_mutation();

CREATE TRIGGER "credit_ledger_entries_append_only_delete"
BEFORE DELETE ON "credit_ledger_entries"
FOR EACH ROW EXECUTE FUNCTION reject_credit_ledger_entry_mutation();
