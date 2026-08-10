CREATE TABLE "family_preferences" (
  "family_id" UUID NOT NULL,
  "version" INTEGER NOT NULL DEFAULT 1,
  "default_reading_reward_seconds" INTEGER NOT NULL DEFAULT 900,
  "session_preset_seconds" INTEGER[] NOT NULL DEFAULT ARRAY[900, 1800, 3600]::INTEGER[],
  "expiration_warning_seconds" INTEGER NOT NULL DEFAULT 60,
  "app_request_behavior" TEXT NOT NULL DEFAULT 'parent_approval',
  "updated_by_parent_id" TEXT,
  "updated_at" TIMESTAMPTZ(6) NOT NULL DEFAULT CURRENT_TIMESTAMP,

  CONSTRAINT "family_preferences_pkey" PRIMARY KEY ("family_id"),
  CONSTRAINT "family_preferences_family_id_fkey"
    FOREIGN KEY ("family_id") REFERENCES "families"("id")
    ON DELETE CASCADE ON UPDATE NO ACTION,
  CONSTRAINT "family_preferences_version_check" CHECK ("version" > 0),
  CONSTRAINT "family_preferences_reward_check"
    CHECK ("default_reading_reward_seconds" BETWEEN 300 AND 86400),
  CONSTRAINT "family_preferences_presets_check" CHECK (
    cardinality("session_preset_seconds") BETWEEN 1 AND 4
    AND "session_preset_seconds" <@ ARRAY[300, 900, 1800, 3600]::INTEGER[]
  ),
  CONSTRAINT "family_preferences_warning_check"
    CHECK ("expiration_warning_seconds" BETWEEN 0 AND 3600),
  CONSTRAINT "family_preferences_app_request_behavior_check"
    CHECK ("app_request_behavior" IN ('parent_approval'))
);
