# Child App Request And Persistent Parent Control Spike Design

## Decision To Prove

PagePass needs to prove this product contract independently of whether the
parent-side `FamilyActivityPicker` lists the child's installed apps:

```text
Child requests one app once
-> parent can see the requested app
-> parent alone classifies it
-> the classification persists
-> parent can change it later without another child request
-> the child device enforces the latest classification
```

This is a new hard gate after the proven local Screen Time control loop and the
proven child-to-parent application-token transfer.

## Existing Evidence

Already proven on physical devices:

* `.child` authorization and guardian approval
* local shield and unlock
* explicit wall-clock session manual stop and automatic expiry re-lock
* selection of one real application token on the child device
* encoding and transfer of that token to the parent device
* rendering the transferred token's app name and icon on the parent device

Not yet proven as one workflow:

* a durable child app request record
* repeated parent policy changes without reopening the child picker
* pending and blocked apps remaining shielded while credit exists
* only `earnedTime` apps opening during an active session
* `alwaysAllowed` remaining open outside a session
* a newly installed, unregistered app remaining blocked by default
* pairing, server authorization, policy synchronization, and multiple-child isolation

## Product Rules

An app has one parent-owned state:

```text
pending        Child requested the app; it remains blocked.
blocked        Parent explicitly denied or blocked it.
earnedTime     It opens only during an explicit Earned Time session.
alwaysAllowed  It remains open whether or not a session is active.
```

Only the parent may transition an item between these states. The child may
create a request but may not update, delete, approve, or replace the resulting
policy item.

The request is a registration event, not a temporary unlock request. Once
registered, the app stays in the parent's managed list until the parent archives
it. A later request for the same child/token returns the existing item instead
of creating a policy bypass.

## Identity And Pairing

Children do not need email/password accounts in MVP.

```text
Parent signs in to PagePass
-> parent creates/selects a child profile
-> parent app creates one pairing session
-> parent app displays a QR and 6-digit fallback code
-> child app uses either credential
-> backend binds the app installation to that child profile
-> backend issues a device credential scoped to that profile and installation
```

The QR and code resolve to the same pairing session. The session expires after
5 minutes and is single-use. The QR carries only a high-entropy opaque token.
Six-digit attempts are rate-limited. Neither credential contains a parent
password, Apple ID, email address, or child personal data.

Apple Family Controls authorization remains a separate system flow. Pairing
identifies the PagePass child profile; it does not grant Screen Time access.

## App Request Flow

1. The child opens `Request an App` in PagePass.
2. PagePass presents an ephemeral `FamilyActivityPicker` initialized with an
   empty `FamilyActivitySelection` and `includeEntireCategory == false`.
3. The child selects exactly one application.
4. PagePass rejects zero apps, multiple apps, categories, and web domains for
   this spike.
5. Before network I/O, the child app stores the token in its local token vault
   under a new client-generated request ID.
6. The child uploads an idempotent request containing the request ID, device
   identity, and opaque encoded token payload.
7. The backend derives the child profile from the scoped device credential; it
   never trusts a caller-supplied `child_profile_id`.
8. The backend creates or returns one durable app catalog item in `pending`.
9. The parent receives a sync update or notification and sees the app name and
   icon by rendering the family-shareable token.
10. The app remains shielded until the parent changes its state.

If token rendering fails on the parent, show a non-actionable diagnostic in the
spike. Do not let the parent approve an unidentified app during validation.

### Why The Child Picker Is The Primary Request Entry

`ShieldActionDelegate` can receive an `ApplicationToken` when the system invokes
the application-specific action callback. That makes a shield button such as
`Ask Parent` a useful future shortcut.

It cannot be the only MVP request source. PagePass default-blocks unknown apps
with an all-categories policy. A shield caused by that policy may invoke the
category callback with an `ActivityCategoryToken`, which does not identify the
exact application the child tried to open. PagePass must never create a
per-application request from a category token.

Therefore:

```text
Primary, deterministic path: child opens PagePass and selects one app in Picker
Optional shortcut: shield action only when an ApplicationToken is actually supplied
Category-token shield action: direct the child to PagePass; do not guess the app
```

## Parent Decision Flow

1. The parent opens the child's app list.
2. The parent chooses `Blocked`, `Earned Time`, or `Always Allowed`.
3. The backend verifies parent membership and writes a new monotonic policy
   version.
4. APNs may prompt the child app to sync, but push is only a hint.
5. The child fetches the latest policy on launch, foreground, network recovery,
   and explicit test refresh.
6. The child resolves server app item IDs to tokens in its local token vault.
7. The child computes and applies the complete policy atomically.
8. The child acknowledges the applied policy version.
9. The parent UI distinguishes `saved`, `sent`, and `applied` rather than
   claiming an immediate remote change.

The parent may change a registered app repeatedly without the child opening the
picker again.

## Token Ownership

Do not use an encoded `FamilyActivitySelection` as the policy database.

```text
Backend AppCatalogItem ID
  -> stable PagePass identity used by parent policy

ChildTokenVaultEntry
  -> local mapping from AppCatalogItem ID to ApplicationToken

Parent token cache
  -> opaque payload used only to render the requested app
```

The backend treats Apple tokens as opaque data and does not infer bundle IDs or
enumerate installed apps. Production storage must encrypt token payloads at
rest and restrict them to the family and active child device.

If authorization is revoked or a token can no longer be applied, the child
fails closed, reports `re-registration-required`, and does not grant free
access. The parent policy item remains visible while the child refreshes its
token mapping.

## Enforcement Model

The default is blocked for every shieldable app that is not an active exception.

### Safari And System-App Coverage

`applicationCategories = .all(except:)` is not a literal all-installed-app
allowlist. Apple intentionally exempts several system apps, including Safari,
from category shielding. PagePass must not rely on category shielding alone for
Safari.

Safari uses a dedicated two-layer policy:

1. Before Safari token enrollment, fail closed with
   `Application(bundleIdentifier: "com.apple.mobilesafari")` in
   `application.blockedApplications`.
2. Initial child setup requires the parent to select Safari once in the child
   `FamilyActivityPicker` and sync that token as a dedicated managed item.
3. With no active Earned Time session, Safari remains blocked. During an active
   session, PagePass removes the bundle-ID block only when Safari is classified
   as `earnedTime` and its token mapping is valid.
4. On manual stop or interval expiry, PagePass reapplies the Safari block before
   settling the session.
5. `Always Allowed` removes both Safari block layers.

The bundle-ID layer hides Safari and prevents launch, so it is a fail-safe, not
the normal request UI. The token layer preserves the app icon, shield UI, and
parent-managed classification. If Safari token enrollment is absent or stale,
PagePass must not grant Safari Earned Time.

With no active session:

```swift
store.shield.applicationCategories = .all(
    except: alwaysAllowedTokens
)
```

With an active session:

```swift
store.shield.applicationCategories = .all(
    except: alwaysAllowedTokens.union(earnedTimeTokens)
)
```

PagePass schedules the session itself, not application usage. Register one
non-repeating `DeviceActivitySchedule` with `events: [:]`; do not create a
`DeviceActivityEvent` for Earned Time apps.

When starting a session or applying a policy change, use fail-closed ordering:

```text
apply no-session/default-block policy
-> validate authorization, token mappings, exception count, and local balance
-> persist session intent and deadline
-> register a fresh non-repeating DeviceActivity interval with events: [:]
-> verify registration and mark the session active
-> apply active-session exceptions and unlock earned-time apps
```

If scheduling cannot be armed, do not unlock earned-time apps. A short
temporary lock while changing policy is acceptable; unmonitored free usage is
not.

Manual stop and expiry reverse this order conservatively:

```text
apply no-session/default-block policy
-> cancel or retire the interval
-> persist an immutable idempotent settlement
-> decrement local spendable balance
-> sync the settlement to the backend
```

Manual stop spends elapsed wall-clock seconds rounded up and capped by the
selected duration. Natural expiry spends the selected duration. The same
session ID cannot produce two ledger spends.

Consequences:

* `pending`, `blocked`, and unregistered shieldable apps remain blocked.
* `alwaysAllowed` apps remain open with or without a session.
* `earnedTime` apps open as a group only during an active explicit session.
* session time is wall-clock time; PagePass does not inspect which unlocked app
  is foregrounded.
* unshieldable Apple system apps may remain usable but do not affect settlement.
* newly installed apps remain blocked without PagePass detecting installation.

The combined `alwaysAllowed` and currently unlocked `earnedTime` exception set
must stay within Apple's `.all(except:)` limit of 50 application tokens. The
MVP must enforce this limit before accepting a parent policy change.

## Minimal Spike Data Model

```text
AppCatalogItem
  id
  child_profile_id
  device_id
  request_id
  opaque_token_payload
  status: pending | blocked | earned_time | always_allowed
  requested_at
  decided_at
  decided_by_parent_id
  policy_version
  archived_at

ChildTokenVaultEntry
  app_catalog_item_id
  encoded_application_token
  token_fingerprint
  created_at
  last_applied_at
  token_status: active | re_registration_required

PolicyApplicationAck
  child_profile_id
  device_id
  policy_version
  applied_at
  result

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

The spike may keep these records in App Group storage and manually transfer
envelopes during Gate A. Gate B moves the same contracts to the thin API.

## Gate A: Apple Capability Proof

Purpose: prove persistent parent control without introducing backend, pairing,
APNs, or account bugs.

Use the same PagePass spike binary on two physical iPhones in the same Family
Sharing group.

Add only these debug surfaces:

```text
Child Request
  request one app
  export request envelope
  import parent policy envelope
  apply policy
  show local token-vault and applied-version diagnostics

Parent Console
  import request envelope
  render app name and icon
  choose state
  export policy envelope
  show persistent managed-app list
```

Manual payload transfer is intentional. It isolates Apple token behavior from
the PagePass network stack.

### Gate A Test Apps

Install at least three ordinary shieldable apps on the child device:

```text
App A: requested and classified as earnedTime
App B: requested and classified as alwaysAllowed
App C: never registered, used as the default-block negative control
```

Do not use Phone, Settings, or another potentially unshieldable system app.

### Gate A Test Cases

#### A0 - PagePass remains available and protected

1. Apply the default-block policy on the authorized child device.
2. Confirm the child can still launch PagePass and open `Request an App`.
3. Attempt to delete PagePass while `.child` authorization remains approved.
4. Confirm iOS prevents deletion without guardian action.

Pass: default blocking does not prevent the request workflow, and the child
cannot remove the authorized parental-control app to bypass enforcement.

#### A1 - Request visibility and persistence

1. Child requests App A.
2. Transfer and import the request on the parent.
3. Confirm the correct name and icon render.
4. Force quit and relaunch the parent app.
5. Confirm App A remains in `pending`.
6. Submit the same request envelope again and confirm it returns the existing
   item instead of creating a duplicate.

Pass: one durable item remains visible without another child picker interaction
and request retries are idempotent.

#### A2 - Pending and blocked fail closed

1. Give the child enough synced test credit to start a session.
2. Leave App A pending and apply policy.
3. Confirm App A remains shielded.
4. Parent changes App A to blocked; transfer and apply the policy.
5. Confirm it remains shielded.

Pass: pending or blocked never becomes an exception because credit or an active
session exists.

#### A3 - Explicit Earned Time session unlock and re-lock

1. Parent changes App A to earnedTime.
2. Child applies the new policy and confirms App A remains locked with no
   active session, even though credit is available.
3. Child starts a 15-minute explicit session and confirms App A opens only
   after schedule registration succeeds.
4. Stop manually and confirm App A re-locks before elapsed wall-clock seconds
   are settled.
5. Start a second 15-minute session, terminate PagePass, and confirm interval
   expiry re-locks App A and settles exactly one session.

Pass: the parent-owned item is the only session exception, manual stop and
expiry both fail closed, and retries cannot double spend.

#### A4 - Always-allowed is independent of a session

1. Child requests App B and parent sets it to alwaysAllowed.
2. With no session active, confirm App B opens and App A remains blocked.
3. Start an Earned Time session, use only App B, and manually stop after a
   measured interval.
4. Confirm the session spends elapsed wall-clock time because the child chose
   to keep the session active, not because App B was monitored.

Pass: App B never requires Earned Time, and PagePass makes no false claim that
it can pause the explicit session based on the foreground app.

#### A5 - Persistent parent reclassification

Without reopening the child picker, run:

```text
App A: earnedTime -> blocked -> alwaysAllowed -> earnedTime
```

Transfer and apply every policy version. Confirm shield and session-exception
behavior after each transition.

Pass: all transitions work from the original request token.

#### A6 - Unregistered and newly installed apps

1. Keep App C unregistered.
2. Apply policy and start an Earned Time session.
3. Confirm App C remains shielded and never becomes a session exception.
4. Install another ordinary app after policy application.
5. Confirm it is also shielded without a PagePass inventory refresh.

Pass: default block covers current and newly installed shieldable apps.

#### A7 - Restart and force-quit durability

1. Apply a mixed policy for Apps A and B.
2. Restart the child device and verify the shield state.
3. Start a 15-minute Earned Time session and force quit PagePass.
4. Confirm the monitor extension re-locks App A at interval expiry before
   PagePass relaunches.
5. Relaunch and confirm recovery produces no duplicate settlement.

Pass: policy and enforcement do not depend on the main app staying alive.

#### A8 - Authorization and token failure

1. Revoke Family Controls authorization.
2. Attempt to apply a policy and record the exact error/state.
3. Confirm PagePass does not report the policy as applied.
4. Re-authorize and re-register only if the token cannot be restored.

Pass: failure is visible, parent authority is retained, and no free-access state
is silently reported as success.

## Gate B: Product Workflow Proof

Purpose: prove identity, pairing, authorization, synchronization, and
multiple-child isolation after Gate A passes.

Build the thinnest backend that supports:

```text
create pairing session
consume QR token or 6-digit code
issue scoped child-device credential
create idempotent app request
list parent app items by child
write parent-only decision and policy version
fetch child policy
ack applied policy version
upsert idempotent Earned Time session settlement
```

APNs is optional for this gate. Both devices must have explicit refresh controls
so delivery reliability cannot hide correctness.

### Gate B Test Cases

#### B1 - QR and numeric-code equivalence

Pair one test installation using QR. Reset it, create a new session, and pair
using the 6-digit code. Confirm both produce the same scoped device capability
and each session is single-use and expires.

#### B2 - Request-to-approval round trip

Request App A on the child, refresh the parent, approve it as earnedTime,
refresh the child, and confirm the exact policy version is applied and
acknowledged.

#### B3 - Child authorization boundary

Attempt to call decision, credit, archive, and policy endpoints with the child
device credential. Every call must be rejected. The child may create requests
only for its own bound profile and device.

#### B4 - Multiple-child isolation

Create two child profiles and pair one installation to each. Confirm:

* requests appear only under the correct child
* a parent decision for Child A never changes Child B
* a Child A credential cannot submit or fetch Child B data
* policy versions and acknowledgements are independent per child/device

#### B5 - Offline and delayed synchronization

Make a parent policy change while the child is offline. Confirm the parent shows
`saved`, not `applied`. Reconnect and foreground the child, then confirm it
fetches, applies, acknowledges, and changes the parent status to `applied`.

#### B6 - Offline session settlement and idempotency

Start a session from already-synced balance, take the child offline, and stop it
manually. Confirm apps re-lock and local balance changes without the API. After
reconnecting, submit the settlement repeatedly and confirm the backend creates
one session and one `spend` ledger row. Repeat with natural expiry while the host
app is terminated.

## Device And OS Matrix

Gate A must pass on physical devices; Simulator results do not count.

Minimum matrix when hardware is available:

| Parent | Child | Purpose |
| --- | --- | --- |
| current iOS | current iOS | normal supported path |
| current iOS | iOS 18.7.9 | mixed-version regression path |

Record exact model, OS build, PagePass build, Family Sharing roles,
authorization status, token counts, policy versions, and timestamps for every
run.

Also open the parent `FamilyActivityPicker` once per matrix row and record
whether it lists child apps. That result does not determine whether the request
workflow passes; it decides whether direct parent selection can be enabled as a
convenience on that environment.

## Pass Criteria

The feature is technically proven only when all of these are true:

```text
one child request produces one durable parent-visible app item
the parent sees the correct name and icon
the parent can reclassify it repeatedly without another child picker action
pending and blocked remain shielded even with available credit or an active session
earnedTime remains locked without a session and unlocks only during one
manual stop and natural expiry both re-lock before an idempotent settlement
alwaysAllowed remains open independently of session state
unregistered/new shieldable apps remain blocked during a session
policy survives app relaunch and child-device restart
child credentials cannot mutate parent policy
two child profiles remain isolated
parent UI reports applied only after child acknowledgement
```

## Blockers

Stop product implementation and revisit the model if any Apple capability fails:

* a child-selected token cannot be persisted across restart
* the transferred token cannot be rendered on the parent in the same family
* the original child token cannot enforce later parent policy transitions
* `.all(except:)` does not default-block an ordinary newly installed app
* an `alwaysAllowed`, pending, blocked, or unregistered app becomes locked or
  unlocked contrary to the explicit exception policy
* a session interval cannot re-lock Earned Time apps with the host terminated
* one session can produce more than one ledger spend
* PagePass can be deleted by the child while `.child` authorization is approved

Backend authorization, retry, or UI failures are implementation defects, not
Apple capability blockers; fix and rerun Gate B.

## Implementation Order

1. Add app-item and token-vault models to the existing spike.
2. Add child request envelope export and parent import/list UI.
3. Add parent policy envelope export and child import/apply UI.
4. Change shield enforcement to default-block with explicit exceptions.
5. Connect `earnedTime` exceptions to the proven explicit wall-clock session
   state machine; schedule the interval with `events: [:]`.
6. Run Gate A on physical devices and archive evidence.
7. Build pairing and the minimal API endpoints.
8. Run Gate B, including authorization and multiple-child isolation.
9. Keep parent direct selection behind a capability flag and test it separately.
10. Merge the proven contracts into the Nx product architecture.

## References

* FamilyActivityPicker: https://developer.apple.com/documentation/familycontrols/familyactivitypicker
* FamilyActivitySelection: https://developer.apple.com/documentation/familycontrols/familyactivityselection
* ApplicationToken: https://developer.apple.com/documentation/managedsettings/applicationtoken
* Shield category policy: https://developer.apple.com/documentation/managedsettings/shieldsettings/activitycategorypolicy/all%28except%3A%29
* DeviceActivitySchedule: https://developer.apple.com/documentation/deviceactivity/deviceactivityschedule
* ShieldActionDelegate: https://developer.apple.com/documentation/managedsettings/shieldactiondelegate
* Family Controls deletion protection: https://developer.apple.com/documentation/familycontrols
