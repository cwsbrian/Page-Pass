import { defineConfig } from "prisma/config";
import { loadRootEnv } from "./apps/api/src/load-env";

loadRootEnv();

export default defineConfig({
  schema: "apps/api/prisma/schema.prisma",
  migrations: {
    path: "apps/api/prisma/migrations"
  },
  datasource: {
    url: process.env.DATABASE_URL,
    shadowDatabaseUrl: process.env.SHADOW_DATABASE_URL
  }
});
