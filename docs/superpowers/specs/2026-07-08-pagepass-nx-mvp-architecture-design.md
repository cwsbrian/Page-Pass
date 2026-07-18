# PagePass Nx MVP Architecture Design

## Status

The local Screen Time loop and explicit wall-clock Earned Time session are
proven on a physical child iPhone XR running iOS 18.7.9. A 15-minute scheduled
session expired with the host app terminated and reapplied the shield; manual
stop also re-locked first and deducted elapsed wall-clock time. Direct parent-side
selection is a supported Apple capability but is blocked in the current device
environment: a fresh clean-room FamilyControls identity still showed no child
applications in the parent `FamilyActivityPicker`. It remains an optional
convenience path. The required Gate 1 is now the child-request and persistent
parent-control workflow defined in
`docs/superpowers/specs/2026-07-14-child-app-request-parent-control-spike-design.md`.
See `docs/manual-tests/2026-07-14-parent-picker-clean-room-result.md` for the
direct-picker evidence.

This spec captures the architecture after the adult/individual Screen Time smoke test. It also corrects the authority model:

```text
Parent controls.
Backend records policy, approvals, and ledger.
Child iPhone enforces.
```

The earlier adult/individual smoke test proved only basic local lock/unlock. The
required child/teen Apple ID `.child` authorization gate has since passed in a
real Family Sharing setup; the remaining hard gate is the productized
child-request, parent-policy, and session-settlement workflow.

## Goal

Design the real MVP architecture around the core product risk:

```text
Can PagePass reliably keep parent-managed apps locked by default, unlock only
the Earned Time set during an explicit child-started session, and re-lock plus
settle elapsed wall-clock time when that session stops or expires?
```

The child device must execute Apple Screen Time enforcement locally because `ManagedSettings` and `DeviceActivity` apply to the current device/user and run through app extensions on that device. The parent is still the control owner: the child app may sync and enforce parent policy, but must not let the child grant credit, change reward rules, or choose a looser policy.

OCR is required for MVP review. AI is optional after the control, OCR, and parent approval loops are stable.

## Hard Gates

These gates happen before full MVP implementation.

### Gate 0: Child Screen Time Proof

Prove Screen Time on a real child/teen iCloud account in Family Sharing:

1. Child device requests Family Controls authorization with `.child`.
2. Parent/guardian approves the request.
3. App appears authorized for Screen Time on the child device.
4. Child device can apply a `ManagedSettings` shield.
5. A non-repeating `DeviceActivity` interval callback fires on the child device.
6. Apps re-lock when the explicit session expires.
7. Behavior survives app backgrounding and force quit.

If this gate fails, do not build the product shell. Redesign around what iOS actually permits.

### Gate 0b: Explicit Earned Time Session Proof

Prove wall-clock sessions independently of per-app usage accounting:

1. Start with a synced local balance of at least 15 minutes.
2. The child explicitly starts a 15, 30, 60 minute, or maximum-balance session.
3. PagePass registers one non-repeating interval with `events: [:]`.
4. Earned Time apps unlock only after schedule registration succeeds.
5. Manual stop reapplies shields before deducting elapsed wall-clock seconds.
6. Natural expiry reapplies shields and settles the selected duration while the
   host app is backgrounded or terminated.
7. Duplicate callbacks and retries cannot spend the same session twice.

This gate passed on iPhone XR/iOS 18.7.9 on 2026-07-17. The observed minimum
accepted duration was 15 minutes; registration failure always fails closed.

### Gate 1: Child App Request And Persistent Parent Control

Prove that the child can register one app token and the parent can retain
complete policy authority over that registered app without physical access to
the child iPhone.

Required architecture:

```text
Child requests one app through the child-device FamilyActivityPicker
-> opaque app token reaches the parent's durable managed-app list
-> parent classifies it as blocked, earnedTime, or alwaysAllowed
-> child device applies the versioned parent policy
-> parent can reclassify it later without another child picker action
```

Pass criteria:

```text
pending and blocked apps remain shielded
earnedTime apps unlock only during an active explicit session
alwaysAllowed apps remain available outside a session
unregistered and newly installed shieldable apps remain blocked by default
parent policy persists and the child cannot mutate it
```

Run the Apple capability proof with manual payload transfer first, then run the
pairing and backend workflow. This keeps Apple token behavior separate from API,
authentication, APNs, and retry defects.

### Gate 1b: Direct Parent Picker Capability

Keep direct parent selection behind a capability flag. Enable it only when the
parent `FamilyActivityPicker` actually returns child application rows in that
family/device environment. Its failure must not block the request workflow.

Apple exposes no supported API for PagePass to enumerate child applications or
manufacture `ApplicationToken` values outside the system picker. PagePass must
not attempt to replace the picker with private APIs.

## Non-Goals

Not in the first MVP architecture:

* Android
* Web dashboard
* Co-parent access
* Multiple devices per child
* Sibling competition
* Shared family-wide credit balance
* AI auto-approval
* Real-time second-by-second countdown
* Full phone lock
* Subscription implementation

## MVP Scope

MVP supports:

```text
One parent account
Multiple child profiles
One active iPhone per child profile
Child-specific limited apps
Child-specific reward rule
Child-specific credit balance
Child-specific submissions and ledger
```

This is the smallest scope that matches the real buyer: one parent may have multiple children, but each child gets one enforcement device in MVP.

Child accounts are profile-and-device based in MVP. Children do not need email/password login. The parent selects a child profile and creates a short-lived pairing session; the parent app shows both a QR and a 6-digit fallback code, and the child app uses either one to bind that installation to the profile.

## Nx Monorepo Shape

Use Nx for TypeScript apps/libs and orchestration. Do not force iOS source into a JavaScript abstraction.

Start small:

```text
apps/
  api/
    Thin API for auth, family, policy, submissions, ledger, device sync.

  mobile-ios/
    Fresh native SwiftUI product app generated from project.yml.
    Contains PagePass, Screen Time extensions, and the PagePassCore package.

libs/
  shared/
    Shared request/response schemas and API types.

spikes/
  screen-time/
    Preserved physical-device proof. It is not a product app dependency.
```

Do not promote or copy the entire spike into `apps/mobile-ios`. Port only the
proven wall-clock schedule, fail-closed shielding, App Group transaction, and
session state-machine behavior. Keep debug consoles, manual transfer tools,
threshold experiments, historical storage keys, and automation harnesses in the
spike. Move the preserved spike under `spikes/` only after the new product bundle
passes the same real-device control-loop test.

Defer separate `db`, `policy`, and `notifications` libs until duplication appears. Migrations and policy validation can live inside `apps/api` at first. APNs helpers can be added when push exists.

Nx targets:

```text
nx run api:build
nx run shared:build
nx run mobile-ios:build
```

`project.yml` and the entitlement files are the source of truth for native target
topology and capabilities. The Nx target regenerates the Xcode project, then
delegates compilation and signing behavior to `xcodebuild`.

## App Roles And Authority

One iOS app can support parent and child roles after login/pairing. The Screen Time extension ships with the app but only performs enforcement on child devices.

### Parent Role

Parent owns:

* child profiles
* limited app policy decisions
* reward ratio and caps
* reading submission review
* approve/reject/ask rewrite
* child credit and status views

Parent must be able to manage multiple children from the first MVP:

```text
Parent Home
  Child card list
    name
    current credit
    pending submissions
    limited app status
    last sync status
```

### Child Role

Child owns only the actions needed to earn and spend credit:

* request child Screen Time authorization
* pair this device to one child profile
* run reading timer
* capture handwritten report photo
* run/show OCR
* submit report
* sync approved credit
* enforce parent policy through Screen Time APIs
* explicitly start and stop Earned Time sessions
* report idempotent session settlements back to backend

Child must not be able to:

* approve submissions
* add credit
* change reward rules
* loosen limited app policy
* delete ledger rows
* switch into parent role without parent authentication

### Role Sessions

* A parent session is authenticated against the parent PagePass account.
* A paired child installation uses a device credential scoped to one child profile.
* A child credential cannot enter parent role or call policy, credit, or ledger mutation endpoints.
* Parent recovery on a paired child device is not part of the app-request workflow.

## Screen Time Control Model

The parent is the control owner, but the child device is the enforcement agent.

```text
Parent app changes policy
-> backend stores policy version
-> child device syncs latest policy
-> child device keeps Earned Time apps shielded while no session is active
-> child explicitly starts an Earned Time session
-> child registers one wall-clock DeviceActivity interval with no usage events
-> child device unlocks the parent-approved Earned Time set
-> manual stop or interval expiry reapplies shields first
-> child device settles elapsed wall-clock time idempotently
-> backend ledger updates canonical balance
```

Backend does not directly shield apps. It sends policy and ledger state to the child device.

## Explicit Earned Time Session Model

MVP spends wall-clock time only after a deliberate child action. It does not
measure foreground time per app and does not create `DeviceActivityEvent`
thresholds.

Runtime behavior:

1. Child syncs a backend balance snapshot. No active session means all
   parent-classified Earned Time apps remain shielded.
2. Child taps `Use Earned Time` and chooses 15, 30, 60 minutes, or the maximum
   available balance. Choices are capped by the local spendable balance.
3. If less than 15 minutes is available, PagePass keeps it saved and does not
   start a session.
4. Child persists a session intent, then registers one non-repeating
   `DeviceActivitySchedule` with `events: [:]` and verifies registration.
5. Only after registration succeeds does PagePass mark the session active and
   unlock the parent-approved Earned Time app set.
6. Manual stop reapplies the no-session shield first, cancels the schedule, and
   spends `ceil(now - started_at)` seconds capped by the selected duration.
7. Natural expiry lets the monitor extension reapply the no-session shield and
   spends the selected duration.
8. Launch/foreground reconciliation repairs interrupted transitions and settles
   an expired active session. A session ID and idempotency key prevent duplicate
   spend.

The 15-minute minimum is a tested product constraint for the current hardware,
not a claim that every iOS release guarantees that exact minimum. Runtime
registration is authoritative; failure leaves apps locked.

## iOS Architecture Boundary

Use feature-scoped SwiftUI MV with `@Observable` stores for screens and ordinary
application state. Keep the Screen Time core narrower: a deterministic reducer
owns `EarnedTimeSession` transitions, and services perform schedule, App Group,
ledger, and shield effects. The app and monitor extension consume the same
serialized session contract.

Do not adopt TCA or a multi-layer Clean Architecture framework for MVP. The
state machine is warranted because it crosses process boundaries; the rest of
the app should stay in native SwiftUI feature modules:

```text
PagePassApp
Features/Parent
Features/Child
Core/APIClient
Core/Identity
Core/Ledger
ScreenTime/Authorization
ScreenTime/Policy
ScreenTime/EarnedTimeSession
ScreenTime/TokenVault
SharedAppGroup
Extensions/DeviceActivityMonitor
```

## Balance Reconciliation

Backend ledger is canonical. Child device keeps a local spendable snapshot for enforcement.

Rules:

* Parent approval creates backend `earn` ledger rows.
* The child device can spend only credit it has already synced.
* Starting a session reserves its selected duration from the local spendable
  snapshot so another local session cannot overspend it.
* Manual stop releases the unconsumed part of that reservation locally after
  the shield is restored; only `consumed_seconds` becomes a spend.
* Offline child devices may start from already-synced balance, but newly earned
  server credit is not usable until the next successful sync.
* Manual stop and expiry create a local immutable session settlement first and
  immediately update the local balance.
* Backend accepts an idempotent settlement only from the active device assigned
  to that child profile.
* Session state is monotonic: `active -> settlement_pending -> settled` or
  `rejected`. A settled session can never become active again.
* Backend validates device/profile ownership, duplicate idempotency keys,
  impossible timestamps, negative durations, duration above the session cap,
  and spend above `balance_before_seconds`.
* If the backend rejects a settlement, the child keeps Earned Time apps locked,
  refetches canonical state, and never restores consumed balance automatically.
* Parent UI shows `last sync`, any pending settlement, and active-session state
  as last reported rather than claiming real-time child status.

This avoids giving credit back locally just because sync failed. The child app remains conservative: when unsure, lock limited apps and refetch.

## Session Sync Contract

The child-device credential uses one idempotent upsert contract keyed by its
client-generated `local_session_id`:

```text
PUT /child-device/earned-time-sessions/:localSessionId
```

The request can carry either the active session snapshot or its final
settlement. The backend derives child and device IDs from the credential, never
from caller-supplied ownership fields. A child that starts offline may upload
the final settlement without first uploading an active state; the backend
records the session and spend atomically. Repeating the same request returns the
same result, while changing immutable duration or start fields is rejected.

Parent reads may expose `active`, `settlement_pending`, and `last_synced_at`, but
these are informational snapshots. They are not a remote timer and are not used
to decide whether the child device should unlock.

## Backend Responsibilities

Backend is the source of truth for:

* parent accounts
* family membership
* child profiles
* active child device registrations
* one-time child-device pairing sessions
* child policies and policy versions
* submissions
* OCR text
* approval state
* canonical credit ledger
* Earned Time session records and settlements
* audit logs
* push notifications after the core loop works

Backend does not need raw app names. It stores opaque selection data only when needed for enforcement sync.

## Core Data Model

```text
ParentUser
  id
  email
  display_name
  created_at

Family
  id
  created_by_parent_id
  name
  created_at

ChildProfile
  id
  family_id
  name
  age
  grade
  timezone
  created_at

Device
  id
  child_profile_id
  app_instance_id
  platform
  device_name
  push_token
  screen_time_authorization_status
  last_policy_applied_version
  last_policy_applied_at
  last_selection_applied_version
  last_selection_applied_at
  last_session_synced_at
  active
  paired_at
  last_seen_at

DevicePairingSession
  id
  child_profile_id
  created_by_parent_id
  qr_secret_hash
  numeric_code_hash
  expires_at
  consumed_at
  consumed_by_app_instance_id
  created_at

ChildPolicy
  id
  child_profile_id
  reward_ratio
  daily_earn_cap_minutes
  policy_version
  updated_by_parent_id
  updated_at

AppCatalogItem
  id
  child_profile_id
  device_id
  request_id
  opaque_token_payload
  status: pending | blocked | earned_time | always_allowed
  policy_version
  requested_at
  decided_at
  decided_by_parent_id
  archived_at

PolicyApplicationAck
  child_profile_id
  device_id
  policy_version
  applied_at
  result
  updated_at

ReadingSession
  id
  child_profile_id
  started_at
  ended_at
  duration_minutes
  status: active | submitted | approved | rejected | rewrite_requested
  created_at

BookReportSubmission
  id
  child_profile_id
  reading_session_id
  book_title
  page_range
  image_url
  ocr_text
  status: submitted | approved | rejected | rewrite_requested
  submitted_at
  reviewed_at
  reviewed_by_parent_id

CreditLedger
  id
  child_profile_id
  type: earn | spend
  amount_seconds
  source_type: reading_session | earned_time_session
  source_id
  idempotency_key
  created_at

EarnedTimeSession
  id
  child_profile_id
  device_id
  local_session_id
  requested_duration_seconds
  balance_before_seconds
  started_at
  expires_at
  ended_at
  consumed_seconds
  end_reason: manual_stop | expired | recovery
  status: active | settlement_pending | settled | rejected
  idempotency_key
  synced_at
```

Constraints:

* one parent-created family in MVP
* many child profiles per family
* at most one active device per child profile
* at most one active Earned Time session per child profile/device
* a child device belongs to exactly one active child profile
* child device credentials are scoped to that one child profile and device
* the QR and 6-digit code resolve to the same short-lived pairing session
* pairing sessions expire after 5 minutes and are single-use
* QR payloads contain only a high-entropy opaque token, never credentials or personal data
* 6-digit code attempts are rate-limited by device, account, and network
* every ledger write has an idempotency key
* `requested_duration_seconds` is at least the runtime-supported minimum and no
  greater than `balance_before_seconds`
* `expires_at` equals `started_at + requested_duration_seconds`
* one settled session maps to exactly one `spend` ledger row

## Credit Rules

First implementation:

```text
current balance seconds = earned seconds - spent seconds
```

Rules:

* parent approval creates `earn`
* a settled explicit session creates one `spend` row
* manual stop spends elapsed wall-clock seconds rounded up and capped by the
  requested duration
* natural expiry spends the requested duration
* session settlement is written locally first, then synced
* child devices can submit sessions only for their own assigned profile/device
* bonus, adjustment, expiry, carryover, and daily usage caps are deferred until the first loop is reliable

## End-To-End MVP Loop

```text
Parent creates family
Parent creates multiple child profiles
Parent selects a child profile and displays its one-time QR plus 6-digit code
Child device scans the QR or enters the fallback code
Backend binds the installation to that child profile and issues a scoped device credential
Child device passes .child Screen Time authorization
Parent configures reward policy for that child
Child requests apps and parent classifies each managed app
Child starts reading
Child limited apps lock
Child finishes reading
Child captures handwritten report photo
Vision OCR produces text
Child submits photo + OCR text
Parent reviews original photo + OCR text
Parent approves
Backend writes credit ledger earn row
Child syncs balance snapshot
Child limited apps remain locked until the child taps Use Earned Time
Child chooses a duration or maximum available balance
Child registers the wall-clock interval and Earned Time apps unlock
Child manually stops, or DeviceActivity intervalDidEnd fires at expiry
Child device re-locks Earned Time apps before settlement
Child syncs the idempotent session settlement
Backend ledger reflects remaining balance
Parent sees updated child status
```

## Sync Model

Keep sync boring:

* child app polls on foreground
* push notifies child after parent approval or policy change after the core loop works
* child app queues session settlements locally if offline
* queued settlements retry with the session idempotency key
* child app applies newest policy only if `policy_version` increases
* child app applies newest limited app selection only if `selection_version` increases
* child app locks limited apps while reconciliation is unknown

Do not build realtime collaboration in MVP.

## OCR Model

OCR is required for MVP but not trusted as proof.

* Run Vision OCR on the child device after photo capture.
* Upload original image and OCR text together.
* Parent review always shows original image and OCR text.
* UI copy says OCR may be imperfect.
* AI review can be added later without changing approval authority.

## Security And Privacy Rules

* no ads
* no third-party tracking
* no location tracking
* no message/content monitoring
* no raw app names required by backend
* store opaque Screen Time selection data only for enforcement
* parent actions are audit logged
* child cannot mutate parent policy or earned credit
* child cannot enter parent role without parent authentication
* photos are scoped to the family
* delete-data path required before launch

## Build Phases

### Phase 0: Child Screen Time Proof Gate

Prove the core Screen Time mechanics on a real child/teen Apple ID in Family Sharing.

Exit criteria:

```text
.child authorization succeeds on child device
guardian approval works
ManagedSettings shield applies
non-repeating DeviceActivity interval starts and ends
manual stop reapplies shields before settlement
natural expiry reapplies shields with the host app terminated
behavior survives app backgrounding and force quit
```

Verified result:

```text
iPhone XR / iOS 18.7.9 / 2026-07-17
manual stop: elapsed wall-clock seconds settled and apps re-locked
15-minute max session: intervalDidEnd re-locked apps after host termination
events: [:]; no per-app usage threshold
```

### Phase 1: App Request And Persistent Parent Control Gate

Prove the workflow in two layers:

* Gate A manually transfers request and policy envelopes between two physical
  devices to isolate Apple token persistence and enforcement.
* Gate B adds QR/6-digit pairing, scoped device credentials, parent-only policy
  APIs, synchronization, acknowledgements, and multiple-child isolation.

Exit criteria:

```text
one child request creates one durable parent-visible app item
parent can repeatedly reclassify it without another child picker action
earnedTime unlocks only inside an explicit session
alwaysAllowed remains available outside a session
unregistered/new shieldable apps remain blocked
child cannot mutate parent policy
```

### Phase 2: Nx Foundation

Create the monorepo and a fresh iOS product app under `apps/mobile-ios`. Preserve
the spike separately and selectively port only proven Screen Time behavior. Keep
shared request/response schemas in one small TypeScript library; session math
remains in the API until another TypeScript consumer needs it.

Exit criteria:

```text
nx run api:build
nx run shared:build
nx run mobile-ios:build
```

Foundation scaffold completed on 2026-07-17. The fresh `com.pagepass.app`
simulator build, monitor-extension embedding, Swift package tests, and iOS test
target pass.

Real-device control-loop parity completed on 2026-07-17 using the child iPhone
XR on iOS 18.7.9:

* `.child` authorization succeeded for the fresh product bundle
* an Earned Time policy applied its no-session Shield
* explicit session start unlocked the configured Earned Time app
* the visible timer tracked the wall-clock deadline
* manual stop re-locked immediately and deducted elapsed wall-clock time
* a 15-minute non-repeating interval expired while PagePass was backgrounded
* `intervalDidEnd` re-applied the Shield and settled the full duration

Force-quit and device-restart recovery remain resilience cases, not blockers for
the proven core loop. The spike remains preserved as separate evidence by
product decision rather than being promoted into the product app.

### Phase 3: Productize Child Enforcement

Productize the behavior proven by the spike as child enforcement services:

* authorization
* local managed-app token vault
* default-block shielding with parent-owned exceptions
* shield control
* explicit Earned Time session state machine
* non-repeating DeviceActivity interval scheduling with no usage events
* idempotent session settlement queue
* local spendable balance
* conservative lock-on-unknown state

Exit criteria:

```text
Child can explicitly start/stop a session, and apps remain locked whenever the
session state is absent, expired, rejected, or unknown.
```

### Phase 4: Backend And Multi-Child Parent Shell

Build the smallest backend and parent UI for:

* family
* multiple child profiles
* one active device per child
* child card list
* child policy
* canonical credit ledger
* sync status

Exit criteria:

```text
Parent can see multiple children and configure child-specific policy.
```

### Phase 5: Reading + OCR + Approval

Build child reading submission and parent review.

Exit criteria:

```text
Child submits photo + OCR.
Parent reviews original photo + OCR.
Parent approves.
Backend creates earn ledger row.
```

### Phase 6: End-To-End Enforcement Loop

Connect approval credit to explicit child sessions and settlement sync.

Exit criteria:

```text
Parent approval adds credit but does not unlock child limited apps.
Child starts an explicit duration or maximum-balance session.
Manual stop and natural expiry re-lock before settlement.
Session settlement syncs to backend idempotently.
Backend ledger reflects wall-clock spend.
Parent sees updated child status.
```

### Phase 7: Distribution Hardening

Add:

* production Family Controls entitlement request
* TestFlight-ready signing
* push notifications
* error states
* privacy copy
* delete-data path
* TestFlight QA checklist

Exit criteria:

```text
End-to-end MVP passes on child Apple ID device and is ready for external testing.
```

## Approval Checklist

This spec is approvable only when these are accepted:

* Child `.child` Screen Time proof is a pre-MVP hard gate.
* Explicit wall-clock Earned Time sessions are physically tested for manual stop
  and natural expiry; per-app automatic usage deduction is out of scope.
* Limited app selection has a chosen architecture or accepted fallback.
* Parent controls policy and approval.
* Backend owns canonical ledger.
* Child iPhone owns local enforcement and local spendable balance.
* MVP supports one parent with multiple child profiles.
* OCR is required before MVP is considered complete.

## References

* Apple Screen Time API documentation: https://developer.apple.com/documentation/screentimeapidocumentation
* Apple AuthorizationCenter documentation: https://developer.apple.com/documentation/familycontrols/authorizationcenter
* Apple FamilyActivityPicker documentation: https://developer.apple.com/documentation/familycontrols/familyactivitypicker
* Apple WWDC22 Screen Time API notes: https://developer.apple.com/videos/play/wwdc2022/110336/
