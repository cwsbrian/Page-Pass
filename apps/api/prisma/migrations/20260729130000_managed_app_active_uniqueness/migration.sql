DROP INDEX "managed_apps_device_client_key";
DROP INDEX "managed_apps_device_token_key";

CREATE UNIQUE INDEX "managed_apps_active_device_client_key"
  ON "managed_apps"("source_device_id", "client_app_id")
  WHERE "archived_at" IS NULL;

CREATE UNIQUE INDEX "managed_apps_active_device_token_key"
  ON "managed_apps"("source_device_id", "token_digest")
  WHERE "archived_at" IS NULL;

CREATE INDEX "managed_apps_device_client_idx"
  ON "managed_apps"("source_device_id", "client_app_id");

CREATE INDEX "managed_apps_device_token_idx"
  ON "managed_apps"("source_device_id", "token_digest");
