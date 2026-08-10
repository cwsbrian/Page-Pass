# PagePass API Deployment

## Runtime Contract

- Build the default `Dockerfile` target for the API runtime.
- Expose container port `8787` behind a TLS-terminating load balancer.
- Route liveness checks to `/health` and readiness checks to `/health/ready`.
- Send `SIGTERM` during rollout and allow the process to close HTTP requests,
  push delivery, media deletion work, Prisma, and PostgreSQL connections.
- Mount the APNs `.p8` file read-only and set `APNS_PRIVATE_KEY_PATH` to that
  mounted path. Never put the key in the image or repository.

## Release Sequence

1. Build one immutable image revision.
2. Build the same Dockerfile's `migrate` target and run it once with the
   production `DATABASE_URL`.
3. Confirm all migrations applied successfully before starting new API tasks.
4. Roll out the runtime image with the complete production environment from
   `.env.example` supplied by a secret manager.
5. Wait for `/health/ready` to return 200 before routing traffic.
6. Smoke test parent sign-in, child snapshot, a signed media URL, and APNs from
   a Release/TestFlight build.
7. Confirm the public `/privacy` and `/terms` pages are reachable over HTTPS and
   use those URLs in App Store Connect after legal review.

Example image builds:

```sh
docker build -t pagepass-api:REVISION .
docker build --target migrate -t pagepass-api-migrate:REVISION .
```

Do not run `prisma migrate dev` in production. Back up PostgreSQL before a
schema rollout and retain the previous runtime image for rollback. Database
migrations are forward-only; rolling back application code must remain
compatible with the migrated schema.

## Required Services

- Managed PostgreSQL with encrypted connections, backups, and point-in-time
  recovery.
- Private S3-compatible storage with encryption at rest and public access
  disabled.
- Resend for account email.
- APNs token authentication for parent and child notifications.
- A TLS endpoint matching the iOS Release `PAGEPASS_API_BASE_URL` and
  `BETTER_AUTH_URL`.

Fastify emits structured request logs with request IDs. The deployment platform
must retain error logs and alert on readiness failures, repeated 5xx responses,
pending/failed push outbox growth, and failed media deletion jobs. No OCR text,
report images, bearer credentials, pairing codes, or APNs tokens may be added to
logs. Apply the database, object-storage, and backup lifecycle described in
[`data-retention.md`](data-retention.md), and alert on retention-worker errors.

## Operational Check

Run the read-only operational check from a scheduled job against the production
database at least every five minutes:

```sh
DATABASE_URL="$PRODUCTION_DATABASE_URL" pnpm ops:check
```

It emits aggregate JSON only and exits non-zero when a threshold is exceeded.
It never selects event payloads, storage keys, credentials, or user/child data.
Alert on command failure and retain the JSON with deployment metrics. The
defaults cover due/failed/stuck push events and due/stuck/high-retry media
deletion jobs. Override them with the `PAGEPASS_OPS_*` variables documented in
`.env.example` after production traffic establishes a baseline. A database
connection or query failure also exits non-zero and must page the operator.
