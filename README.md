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
pnpm db:start
pnpm storage:start
pnpm db:deploy
pnpm dev:api
pnpm exec nx show projects
pnpm exec nx run api:test
pnpm exec nx run api:better-auth-integration-test
pnpm exec nx run api:family-integration-test
pnpm exec nx run api:legacy-family-claim-integration-test
pnpm exec nx run api:reading-integration-test
pnpm exec nx run api:media-storage-integration-test
pnpm ops:check
pnpm exec nx run api:prisma-generate
pnpm exec nx run api:prisma-validate
pnpm exec nx run mobile-ios:test
pnpm exec nx run mobile-ios:release-verify
pnpm exec nx run mobile-ios:generate
pnpm exec nx run mobile-ios:build
```

`mobile-ios:generate` requires XcodeGen. `project.yml` is the source of truth for
the generated Xcode project. `mobile-ios:test` runs the portable `PagePassCore`
tests, iOS app tests, and accessibility UI audits on an available iPhone
Simulator. The UI suite covers role selection, Parent Home, Child Home, and the
largest accessibility Dynamic Type size. Set `PAGEPASS_IOS_SIMULATOR_UDID` to
select a specific simulator.

`mobile-ios:release-verify` builds a Release simulator bundle and fails when the
production API URL, ATS policy, compiled development credentials, localized
privacy prompts, bundle identifiers, or target Privacy Manifests do not match
the release contract.

## Production Configuration

`project.yml` injects the API base URL and development parent credential into
the app Info.plist. Debug builds may use the LAN HTTP API and local parent
credential; Release builds use `https://api.pagepass.app`, reject non-HTTPS API
URLs at runtime, and contain no local credential. Override
`PAGEPASS_API_BASE_URL` in the Release build settings when the production API
host changes.

User-facing source strings are compiler-extracted into
`App/Localizable.xcstrings`; privacy permission prompts use
`App/InfoPlist.xcstrings`. English is currently the only declared app language.
Add reviewed translations in the catalogs rather than branching on locale in
Swift code.

The API fails closed when `NODE_ENV=production`: `PAGEPASS_AUTH_MODE` must be
`apple`; Better Auth, trusted web origins, and S3 must use HTTPS; and Resend,
Apple authentication, APNs, and S3 credentials must all be configured. The
complete contract is documented in `.env.example` and covered by API tests.
Container rollout, migration ordering, health checks, secret handling, and
monitoring expectations are documented in
[API deployment](docs/operations/deployment.md). Public legal pages are served
at `/privacy` and `/terms`; publish them over the production HTTPS domain only
after legal review.

## Local PostgreSQL

The API uses PostgreSQL; SQLite is not supported. Create a local `.env` from
`.env.example`, replace its development secrets, then start PostgreSQL and apply
the append-only migrations:

```sh
cp .env.example .env
pnpm db:start
pnpm db:deploy
```

Commit both `schema.prisma` and every generated migration. Production and CI use
`pnpm exec nx run api:migrate-deploy`; they must never run `migrate-dev`.

## Private Media Storage

Handwritten-report images use S3-compatible private object storage. Local
development runs MinIO with `pnpm storage:start`. Set `S3_ENDPOINT` to a LAN
address when testing on physical devices because the API returns signed URLs
that the iPhone opens directly. Run `api:media-storage-integration-test` to
verify the complete signed PUT, metadata inspection, and signed GET path.

## Authentication And Email

Parent authentication uses Better Auth with Prisma-backed `users`, `sessions`,
`accounts`, and `verifications`. `/api/auth/*` is the canonical auth surface.
The existing `/v1/auth/apple/*` routes remain temporarily for installed native
builds and will be removed after the iOS client migration.

Email verification and password reset use Resend. Development and test log the
message when `RESEND_API_KEY` is unset; production refuses to start without it.
Child device credentials remain separate from Better Auth because they are
restricted to one child profile and active device.

## Parent Push Notifications

Parent app requests use APNs alert notifications backed by a transactional
PostgreSQL outbox. Configure all four `APNS_*` variables from `.env.example`.
Keep the `.p8` key outside source control; local `AuthKey_*.p8` files are ignored,
while deployed environments should mount the key or provide it through their
secret manager. Debug builds register sandbox tokens and Release builds register
production tokens. The client refreshes canonical API state after receiving a
push and uses app launch, foreground activation, and manual refresh as fallback;
it does not poll continuously.

## Product Documentation

- [Frontend information architecture](docs/product/frontend-information-architecture.md)
- [MVP API design](docs/product/api-design.md)
- [MVP PostgreSQL ERD](docs/product/pagepass-mvp.erd)
- [MVP implementation status](docs/product/mvp-implementation-status.md)
- [API deployment](docs/operations/deployment.md)
- [Data retention](docs/operations/data-retention.md)
- [App Store release checklist](docs/operations/app-store-release.md)
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
settlement, background expiry/re-lock, force-quit recovery, and delayed offline
settlement on an iPhone XR running iOS 18.7.9. Reboot and Screen Time
authorization-revocation recovery remain physical-device checks.
