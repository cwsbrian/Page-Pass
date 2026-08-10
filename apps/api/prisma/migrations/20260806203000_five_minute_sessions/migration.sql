ALTER TABLE "earned_time_sessions"
  DROP CONSTRAINT "earned_time_sessions_duration_valid";

ALTER TABLE "earned_time_sessions"
  ADD CONSTRAINT "earned_time_sessions_duration_valid"
  CHECK ("requested_duration_seconds" BETWEEN 300 AND 86400);
