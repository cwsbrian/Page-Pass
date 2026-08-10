# PagePass MVP Implementation Status

## Status

- Audited: 2026-08-06
- Sources of truth: `frontend-information-architecture.md`, `api-design.md`,
  `pagepass-mvp.erd`, the current Prisma schema, API routes, iOS sources, and
  executable tests.
- This file tracks implementation evidence. A designed item is not marked done
  until its runtime path and required tests exist.

## Proven Foundations

- One native iOS app with Parent and Child installation roles.
- Child QR and six-digit pairing with scoped device credentials.
- Child-side Family Controls authorization, managed-app selection, Shield
  application, policy synchronization, and parent app-policy decisions.
- Wall-clock Earned Time prepare, activate, manual stop, expiry, settlement,
  credit ledger, and background re-lock control loop.
- Multiple child profiles under one family boundary.
- Parent More includes Manage Children for active-child name changes and
  history-preserving archive. Archive is family-scoped and idempotent, rejects
  unsettled Earned Time, disconnects device credentials and push registrations,
  invalidates pairing, and removes the child from active dashboards without
  deleting reading, review, credit, or session history. Pairing and credit
  mutations are serialized with archive, and a revoked child installation
  clears its local PagePass schedule, policy, and restrictions on its next sync.
- Manage Children lists archived profiles separately and exposes their preserved
  reading reports, handwritten evidence, and paginated credit ledger as read-only
  history. Archived profiles stay out of active dashboards, and review, credit,
  policy, pairing, and profile mutations remain active-child only. In-flight
  reading writes revalidate under the archive lock, pending presigned uploads are
  deleted after URL expiry and retained daily deletion tombstones catch late
  uploads. Remote archive refreshes purge stale writable UI.
- Previous-family import now verifies the legacy parent credential and
  atomically migrates every legacy child, credit grant/spend history, canonical
  balance, and active device credential into the authenticated Better Auth
  family. Imported devices remain fail-closed in `pending_setup`; retries are
  idempotent and a second family cannot claim the same data.
- Better Auth, Prisma/PostgreSQL, email delivery adapter, and parent push
  notification backend foundations.
- Parent APNs registration and app-request notification delivery.
- On-device handwritten-report capture and Vision OCR proof UI.
- Reading submission PostgreSQL foundation: private media, evidence, OCR
  revisions, reviews, and append-only review history.
- S3-compatible private media storage with signed upload/read URLs and verified
  content type, byte size, and SHA-256 metadata.
- Child reading flow: cloud draft, multi-page capture, local OCR, upload,
  transcript correction, submit, requested-changes transcript edit/resubmit,
  and durable interrupted-upload recovery.
- Parent reading inbox/detail with original evidence, transcript review, and an
  atomic approval transaction that creates exactly one credit-ledger entry.
- Reading lifecycle, ownership, concurrency, idempotency, stale-version,
  overflow rollback, and signed-storage integration tests.
- Parent Better Auth email sign-up, verification callback/resend, sign-in,
  password-reset deep link, Keychain bearer-session recovery, sign-out, and
  legacy Apple-session cleanup migration.
- Child reading submission parent push notification and exact-report deep link;
  foreground delivery refreshes data without forcing navigation.
- Parent `Home | Requests | Journal | More` and Child
  `Home | Earn | Journal | More` tab shells, with a shared parent data store and
  pending-request badge.
- Parent unified pending inbox plus child/status/title Journal filtering, and
  Child Journal list/detail with transcript and parent-review history.
- Submission-time local recovery bundle for normalized report pages and OCR
  metadata. Interrupted uploads survive app relaunch, reconcile completed
  server pages, retry only incomplete work, and require explicit discard.
- Child-scoped signed media reads with cross-child denial, original handwritten
  pages in Child Journal detail, and immediate Journal state updates after a
  changes-requested resubmission.
- Child APNs registration with paired-device credentials, transactional reading
  review-decision notifications, duplicate suppression, and exact-report Journal
  deep links for approved, changes-requested, and rejected decisions.
- Pre-submit local autosave for book metadata, original pages, OCR state, and
  corrected transcript. Relaunch restores completed OCR without rerunning Vision.
- Changes-requested page replacement reuses the existing submission, reconciles
  interrupted uploads, removes superseded evidence, and safely resumes resubmit.
- Child Journal supports same-device draft continue/delete, interrupted
  processing recovery through the durable upload bundle, and rejected-report
  revision as a new submission linked with `supersedesSubmissionId`.
- Parent Home aggregate returns all active children with exact balance, setup and
  device status, last sync, active session, pending reading/app counts, and family
  attention totals in one family-scoped query. The iOS dashboard uses this model.
- Child Home is now the daily Earned Time surface with shared balance, session,
  loading, sync, and error state. Pairing, Screen Time authorization, managed-app
  selection, app requests, and verification controls live in Child More without
  exposing a child-side unpair or policy-relaxing reset.
- Parent child detail now shows active, pending, replaced, and revoked device
  history. Parent-owned revoke atomically invalidates credentials and push tokens,
  rejects unsettled Earned Time, and unlocks a child-side installation reset only
  after the revoked credential receives an authoritative 401 response.
- Parent child detail includes paginated immutable balance history for parent
  grants, reading rewards, Earned Time spends, and adjustments, with each row's
  signed amount, resulting balance, reason, timestamp, and ledger revision.
- Parent Requests is a unified reading/app history with child, request type, and
  pending/resolved filters. Reading rows open the exact review and app rows open
  the child's policy/request surface.
- Child Earned Time now uses an explicit 15/30/60-minute or Max confirmation
  sheet with end time, affected-app count, and post-session balance. Manual stop
  requires a second confirmation showing elapsed use and remaining credit.
- Parent Add Time supports 15/30/60-minute and custom grants from Home or child
  detail, requires a visible reason, previews the resulting balance, and persists
  the full amount/reason/idempotency payload for exact network retries.
- Parent account deletion requires a recent sign-in and explicit confirmation.
  Shared families transfer ownership; a final parent cannot delete through an
  unsettled Earned Time session, and final-family deletion revokes devices,
  scrubs reading/OCR content, and queues private media deletion with retries.
  Final-family deletion holds every child mutation lock while rechecking and
  scrubbing, so concurrent reading or policy writes cannot recreate private data.
- Versioned family settings let a parent choose 5/15/30/60-minute Earned Time
  presets and a default reading reward. Child snapshots carry the presets and
  Parent review uses the configured reward while retaining Max as a balance-based
  choice.
- Child More includes a privacy-safe diagnostics surface for connection/setup,
  Screen Time authorization, local policy readiness, managed-app count, pending
  settlements, sync revisions, and app version, with a shareable support report.
- Child devices now send authenticated, append-only Screen Time status reports
  after sync and control-state changes. Parent child detail shows the latest
  authorization, policy-application, app version, and pending-settlement state
  without claiming the Shield was remotely verified. Parent Home treats missing,
  stale, unknown, failed, or policy-behind reports as device attention. Exact
  retries are idempotent, conflicting retries are rejected, and reports expire
  after 30 days.
- Per-parent notification settings control reading reports, app requests, device
  policy failures, and Earned Time completion. APNs recipient selection applies
  each preference, and device/session outbox events are created atomically with
  the state change that triggered them.
- Release networking is build-configured and HTTPS-only, with no compiled local
  parent credential. Production API startup requires Apple auth, Resend, APNs,
  private S3 media, and HTTPS service origins.
- Physical force-quit recovery and delayed offline settlement have passed. App
  Group relaunch persistence, parent APNs token rotation/invalid-token cleanup,
  child credential rotation, and device replacement are covered by automated
  integration tests.
- The production API has cache-independent build and test coverage, a non-root
  container image, a migration-only image target, PostgreSQL/S3 readiness,
  liveness, graceful shutdown, and fail-closed production configuration.
- Push and media-deletion workers isolate and report background database
  failures instead of producing unhandled process rejections.
- `pnpm ops:check` provides a read-only, privacy-safe production monitor for due,
  failed, delayed, or stuck push events and delayed/high-retry media deletion
  work. It emits aggregate JSON and fails scheduled jobs when configured
  thresholds are exceeded; production scheduler and alert-provider wiring remain.
- Public `/privacy` and `/terms` pages mirror the app's current legal copy and
  are covered by HTTP route tests. Production hosting and legal review remain.
- A daily retention worker removes expired authentication, pairing, revoked
  credential, push-outbox, and completed media-deletion operational data. The
  implemented deletion behavior and remaining legal decisions are documented.
- App and monitor Privacy Manifests declare their target-specific UserDefaults
  reasons; the app also declares linked account, device, reading-content, and
  product-interaction collection with no tracking. A Release bundle inspection
  confirms both manifests are embedded in the correct executable bundles.
- Automated accessibility audits pass for installation role selection, Parent
  Home, and Child Home. A separate UI test launches Child Home at the largest
  accessibility Dynamic Type size and verifies its primary flow remains
  reachable.
- Compiler-extracted String Catalogs cover 299 user-facing source keys and both
  privacy permission prompts. Computed status and duration labels use localized
  strings or locale-aware format styles; English remains the only declared app
  language until translations are product-reviewed.
- `mobile-ios:release-verify` builds and inspects a Release bundle for production
  HTTPS configuration, hardened ATS, absent development credentials, bundle
  identifiers, localized privacy prompts, both target Privacy Manifests, Family
  Controls/App Group configuration, and target-specific APNs source settings.
  `mobile-ios:archive-verify` separately inspects the actual signed archive for
  production APNs, embedded Family Controls/App Group entitlements, bundle
  identifiers, and a matching signing team.

## In Progress

- Handwritten OCR accuracy proof on representative real reports. The code path
  exists; Korean, mixed-language, low-quality, and multi-page evidence remains.
- Reading vertical-slice real-device proof remains pending because a
  representative handwritten report is not currently available.
- Accessibility code audit has added an explicit OCR-clear label and hint,
  selected traits for Earned Time choices, VoiceOver focus restoration after
  Earned Time sheets, adaptive Parent/Child home layouts, and automated audits.
  Manual VoiceOver and Voice Control walkthroughs remain release gates.

## Remaining Work

### P0 Product Loop

1. Real-report OCR proof and failure-mode validation when representative
   handwritten reports are available.

### P1 Resilience And Release

1. Reboot and Screen Time authorization-revocation physical proof gates.
2. Release/TestFlight APNs delivery, reinstalled-device token rotation, and
   terminated-state notification tap recovery.
3. Publish the privacy/terms pages over the production HTTPS domain after legal
   review, then add those URLs to App Store Connect.
4. Legal approval of backup and pseudonymous-record retention, accessibility,
   production alert-provider wiring, and App Store production-entitlement work;
   product approval of any language added beyond the current English catalog.

## Execution Order

1. Complete device-independent production hosting/monitoring and release
   preflight work.
2. Resume the physical resilience and TestFlight notification gates when the
   required devices and production services are available.
3. Run the real-device reading/OCR proof when representative handwritten reports
   are available.

The order keeps the already-proven Screen Time loop stable while completing the
core product value: a child submits a handwritten report, a parent reviews it,
and approval creates durable Earned Time.
