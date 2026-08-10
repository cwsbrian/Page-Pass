ALTER TABLE "earned_time_sessions"
  DROP CONSTRAINT IF EXISTS "earned_time_sessions_duration_valid";

ALTER TABLE "earned_time_sessions"
  ADD CONSTRAINT "earned_time_sessions_duration_valid" CHECK (
    "requested_duration_seconds" BETWEEN 300 AND 86400
    OR (
      "requested_duration_seconds" BETWEEN 1 AND 299
      AND "state" IN ('settled', 'cancelled', 'rejected')
      AND "created_at" < TIMESTAMPTZ '2026-08-07 00:00:00+00'
    )
  );
