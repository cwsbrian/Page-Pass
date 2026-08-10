CREATE TABLE "parent_preferences" (
  "parent_id" TEXT NOT NULL,
  "reading_requests_enabled" BOOLEAN NOT NULL DEFAULT TRUE,
  "app_requests_enabled" BOOLEAN NOT NULL DEFAULT TRUE,
  "device_alerts_enabled" BOOLEAN NOT NULL DEFAULT TRUE,
  "session_ended_enabled" BOOLEAN NOT NULL DEFAULT TRUE,
  "updated_at" TIMESTAMPTZ(6) NOT NULL DEFAULT CURRENT_TIMESTAMP,

  CONSTRAINT "parent_preferences_pkey" PRIMARY KEY ("parent_id"),
  CONSTRAINT "parent_preferences_parent_id_fkey"
    FOREIGN KEY ("parent_id") REFERENCES "users"("id")
    ON DELETE CASCADE ON UPDATE CASCADE
);
