-- Track the one-time transfer from the legacy local/Apple-owned tables into
-- the Better Auth family model. The family UUID is intentionally historical
-- metadata rather than a foreign key so account deletion can archive data
-- without making the claim proof reusable.
ALTER TABLE "server_state"
    ADD COLUMN "local_data_migrated_family_id" UUID,
    ADD COLUMN "local_data_migrated_children" INTEGER;

ALTER TABLE "server_state"
    ADD CONSTRAINT "server_state_local_migration_consistent"
    CHECK (
        ("local_data_migrated_family_id" IS NULL
            AND "local_data_migrated_children" IS NULL)
        OR
        ("local_data_migrated_family_id" IS NOT NULL
            AND "local_data_migrated_children" IS NOT NULL
            AND "local_data_migrated_children" >= 0)
    );
