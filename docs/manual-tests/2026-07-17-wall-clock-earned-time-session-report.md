# Wall-Clock Earned Time Session Report

Raw capture paths in this report are provenance references governed by
[`EVIDENCE_POLICY.md`](EVIDENCE_POLICY.md); the referenced artifacts are not
stored in Git.

## Decision

The explicit Earned Time session design is viable on the tested iPhone XR.
PagePass can unlock selected apps for a user-started wall-clock session, deduct
only the elapsed session time on manual stop, and automatically reapply the
Shield at the selected deadline without measuring per-app usage.

This should replace automatic app-usage debit as the primary Earned Time model.

## Tested Device

| Device | OS | App | Selection |
| --- | --- | --- | --- |
| iPhone XR | iOS 18.7.9 | `com.pagepass.controlspike` | 1 application token |

The app, Device Activity monitor extension, and Device Activity report
extension were signed and installed together.

## Implementation

- A session stores its starting balance, selected duration, start time,
  deadline, status, consumed seconds, and settlement time.
- Starting a session applies a restrictive Shield first, registers an absolute
  nonrepeating `DeviceActivitySchedule`, verifies schedule readback and zero
  usage events, persists the active state, and then removes the Shield.
- Manual stop applies the Shield before committing the ended state and deducts
  `ceil(elapsed wall-clock seconds)`, capped by the selected duration.
- Automatic expiry is handled by `intervalDidEnd`; it applies the Shield and
  settles the selected duration atomically through the shared App Group state.
- Repeated or stale callbacks cannot debit twice because the run identity and
  active session status must still match.
- If the host app opens after a missed deadline, it reconciles the persisted
  deadline and fails closed.

No `DeviceActivityEvent` is registered for this mode. App usage, background
execution, Notes usage, and Home Screen time are not inputs to the calculation.

## Physical Results

### Minimum schedule probe

A 300-second schedule was rejected by iOS 18.7.9 with:

```text
The activity's schedule is too short
```

The failure was closed: the selected app stayed shielded and the 600-second
balance was not debited. A 900-second schedule registered successfully with
matching schedule readback and zero events. PagePass now enforces a 15-minute
minimum for this implementation.

### Manual stop

```text
Starting balance:  1800 seconds
Selected duration: 900 seconds
Measured elapsed:  245.742 seconds
Charged:           246 seconds
Remaining balance: 1554 seconds
Final Shield:      applied
Active run:        cleared
```

The result exactly matches the defined ceiling rule:
`1800 - ceil(245.742) = 1554`.

### Maximum-time automatic expiry

```text
Starting balance:  900 seconds
Selected duration: 900 seconds (maximum)
Host app:          terminated after session activation
Pre-expiry samples: 900 seconds, unshielded, active
Final balance:     0 seconds
Final Shield:      applied
Active run:        cleared
Consumed:          900 seconds
Callback latency:  about 2.85 seconds after the persisted deadline
```

The extension callback arrived without relaunching PagePass or waking a target
app. Unified logs show `ManagedSettings` successfully applying the selected
application Shield, and the persisted event records
`fail-closed shield applied=true`.

## Automated Tests

All 73 tests passed on the iOS simulator. Wall-clock coverage includes:

- manual elapsed-time settlement
- selected-duration expiry with unused balance preserved
- maximum-duration expiry consuming the balance
- duplicate end callback idempotency
- unlock rejection after expiry
- state Codable round trip
- rejection below the 15-minute Device Activity minimum
- acceptance at the 15-minute minimum

## Adversarial Review

No implementation blocker remains for this control loop.

- Registration failure leaves the app shielded and preserves balance.
- State is activated before the restrictive Shield is removed.
- Stop and expiry apply the Shield before the ended state is committed.
- Host reconciliation and extension expiry are serialized by the App Group
  lock and cannot both charge the session.
- Missing-monitor recovery charges only elapsed time and immediately reshields.
- Authorization loss follows the existing fail-closed recovery path.

## Remaining Constraints

- The 15-minute minimum is an observed requirement on iOS 18.7.9, not a timing
  SLA guaranteed by Apple documentation. Test the same boundary on supported
  iOS versions and retain the runtime registration failure path.
- `intervalDidEnd` delivery is not an exact real-time alarm. The tested callback
  arrived about 2.85 seconds late; the host deadline reconciliation remains
  necessary when the app next opens.
- This proves the local child-device control loop. Parent-child balance grants,
  approvals, and server synchronization remain separate work.

## Evidence

- `docs/manual-tests/evidence/2026-07-17-ios18/wall-clock-manual-stop-r68`
- `docs/manual-tests/evidence/2026-07-17-ios18/wall-clock-auto-expiry-r69`
- Simulator result: `Test-PagePassControlSpike-2026.07.17_10-26-52--0700.xcresult`
