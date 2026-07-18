# PagePass

PagePass is an Nx monorepo with a native SwiftUI iOS product app. The original
Screen Time spike remains separate as validation evidence and is not the product
application.

## Workspace

```text
apps/api                 Thin API boundary and contract validation
apps/mobile-ios          Fresh PagePass product app and monitor extension
libs/shared              Shared runtime API schemas and types
spikes/screen-time       Preserved Screen Time proof project and harnesses
```

## Commands

```sh
pnpm install
pnpm exec nx show projects
pnpm exec nx run api:test
pnpm exec nx run api:prisma-generate
pnpm exec nx run api:prisma-validate
pnpm exec nx run mobile-ios:test
pnpm exec nx run mobile-ios:generate
pnpm exec nx run mobile-ios:build
```

`mobile-ios:generate` requires XcodeGen. `project.yml` is the source of truth for
the generated Xcode project.

## Local PostgreSQL

The API uses PostgreSQL; SQLite is not supported. Start the Docker database and
run the append-only migrations with runtime secrets:

```sh
export PAGEPASS_DB_PASSWORD='choose-a-local-password'
export DATABASE_URL="postgres://pagepass:${PAGEPASS_DB_PASSWORD}@127.0.0.1:54329/pagepass"
docker compose up -d --wait postgres
pnpm exec nx run api:migrate-dev
```

Commit both `schema.prisma` and every generated migration. Production and CI use
`pnpm exec nx run api:migrate-deploy`; they must never run `migrate-dev`.

## Product Documentation

- [Frontend information architecture](docs/product/frontend-information-architecture.md)
- [MVP API design](docs/product/api-design.md)
- [MVP PostgreSQL ERD](docs/product/pagepass-mvp.erd)
- [MVP architecture](docs/superpowers/specs/2026-07-08-pagepass-nx-mvp-architecture-design.md)
- [Wall-clock Earned Time verification](docs/manual-tests/2026-07-17-wall-clock-earned-time-session-report.md)

## iOS Identities

```text
App:       com.pagepass.app
Monitor:   com.pagepass.app.DeviceActivityMonitor
App Group: group.com.pagepass.app
```

The new product identity does not inherit the spike's Family Controls approval,
App Group state, or application tokens. Real-device testing must authorize and
configure the product app independently. Keep the spike installed only when it
is needed for comparison because iOS permits Family Controls authorization for
only one application at a time in the tested environment.

The fresh product bundle passed authorization, manual stop/re-lock, elapsed-time
settlement, and background 15-minute expiry/re-lock on an iPhone XR running iOS
18.7.9 on 2026-07-17. Force-quit and reboot recovery are the remaining native
resilience checks.
