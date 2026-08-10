-- Better Auth family model. Legacy children/active_devices stay in place until
-- an authenticated parent explicitly claims them into this model.

CREATE TABLE "families" (
    "id" UUID NOT NULL DEFAULT gen_random_uuid(),
    "name" TEXT NOT NULL,
    "created_by_user_id" TEXT NOT NULL,
    "status" TEXT NOT NULL DEFAULT 'active',
    "created_at" TIMESTAMPTZ(6) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updated_at" TIMESTAMPTZ(6) NOT NULL,

    CONSTRAINT "families_pkey" PRIMARY KEY ("id"),
    CONSTRAINT "families_name_length"
        CHECK (length("name") BETWEEN 1 AND 100),
    CONSTRAINT "families_status_known"
        CHECK ("status" IN ('active', 'archived'))
);

CREATE TABLE "family_members" (
    "family_id" UUID NOT NULL,
    "user_id" TEXT NOT NULL,
    "role" TEXT NOT NULL DEFAULT 'parent',
    "status" TEXT NOT NULL DEFAULT 'active',
    "joined_at" TIMESTAMPTZ(6) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "left_at" TIMESTAMPTZ(6),

    CONSTRAINT "family_members_pkey" PRIMARY KEY ("family_id", "user_id"),
    CONSTRAINT "family_members_role_known"
        CHECK ("role" IN ('owner', 'parent')),
    CONSTRAINT "family_members_status_known"
        CHECK ("status" IN ('active', 'left')),
    CONSTRAINT "family_members_left_at_consistent"
        CHECK (
            ("status" = 'active' AND "left_at" IS NULL)
            OR ("status" = 'left' AND "left_at" IS NOT NULL)
        )
);

CREATE TABLE "child_profiles" (
    "id" UUID NOT NULL DEFAULT gen_random_uuid(),
    "family_id" UUID NOT NULL,
    "name" TEXT NOT NULL,
    "timezone" TEXT NOT NULL DEFAULT 'UTC',
    "profile_media_id" UUID,
    "status" TEXT NOT NULL DEFAULT 'active',
    "created_by_user_id" TEXT NOT NULL,
    "archived_at" TIMESTAMPTZ(6),
    "created_at" TIMESTAMPTZ(6) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updated_at" TIMESTAMPTZ(6) NOT NULL,

    CONSTRAINT "child_profiles_pkey" PRIMARY KEY ("id"),
    CONSTRAINT "child_profiles_name_length"
        CHECK (length("name") BETWEEN 1 AND 100),
    CONSTRAINT "child_profiles_timezone_length"
        CHECK (length("timezone") BETWEEN 1 AND 100),
    CONSTRAINT "child_profiles_status_known"
        CHECK ("status" IN ('active', 'archived')),
    CONSTRAINT "child_profiles_archived_at_consistent"
        CHECK (
            ("status" = 'active' AND "archived_at" IS NULL)
            OR ("status" = 'archived' AND "archived_at" IS NOT NULL)
        )
);

CREATE TABLE "devices" (
    "id" UUID NOT NULL DEFAULT gen_random_uuid(),
    "child_profile_id" UUID NOT NULL,
    "installation_id" TEXT NOT NULL,
    "device_name" TEXT NOT NULL,
    "platform" TEXT NOT NULL DEFAULT 'ios',
    "status" TEXT NOT NULL DEFAULT 'pending_setup',
    "app_version" TEXT NOT NULL,
    "app_build" TEXT NOT NULL,
    "paired_at" TIMESTAMPTZ(6) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "ready_at" TIMESTAMPTZ(6),
    "retired_at" TIMESTAMPTZ(6),
    "revoked_at" TIMESTAMPTZ(6),
    "last_seen_at" TIMESTAMPTZ(6),
    "created_at" TIMESTAMPTZ(6) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updated_at" TIMESTAMPTZ(6) NOT NULL,

    CONSTRAINT "devices_pkey" PRIMARY KEY ("id"),
    CONSTRAINT "devices_name_length"
        CHECK (length("device_name") BETWEEN 1 AND 100),
    CONSTRAINT "devices_platform_known"
        CHECK ("platform" IN ('ios')),
    CONSTRAINT "devices_status_known"
        CHECK ("status" IN ('pending_setup', 'active', 'retired', 'revoked'))
);

CREATE INDEX "family_members_user_status_idx"
    ON "family_members"("user_id", "status");
CREATE UNIQUE INDEX "family_members_one_active_family_per_user"
    ON "family_members"("user_id")
    WHERE "status" = 'active';
CREATE INDEX "child_profiles_family_status_idx"
    ON "child_profiles"("family_id", "status");
CREATE UNIQUE INDEX "devices_installation_id_key"
    ON "devices"("installation_id");
CREATE INDEX "devices_child_status_idx"
    ON "devices"("child_profile_id", "status");
CREATE UNIQUE INDEX "devices_one_active_per_child"
    ON "devices"("child_profile_id")
    WHERE "status" = 'active';

ALTER TABLE "family_members"
    ADD CONSTRAINT "family_members_family_id_fkey"
    FOREIGN KEY ("family_id") REFERENCES "families"("id")
    ON DELETE NO ACTION ON UPDATE NO ACTION;

ALTER TABLE "family_members"
    ADD CONSTRAINT "family_members_user_id_fkey"
    FOREIGN KEY ("user_id") REFERENCES "users"("id")
    ON DELETE CASCADE ON UPDATE CASCADE;

ALTER TABLE "child_profiles"
    ADD CONSTRAINT "child_profiles_family_id_fkey"
    FOREIGN KEY ("family_id") REFERENCES "families"("id")
    ON DELETE NO ACTION ON UPDATE NO ACTION;

ALTER TABLE "devices"
    ADD CONSTRAINT "devices_child_profile_id_fkey"
    FOREIGN KEY ("child_profile_id") REFERENCES "child_profiles"("id")
    ON DELETE NO ACTION ON UPDATE NO ACTION;
