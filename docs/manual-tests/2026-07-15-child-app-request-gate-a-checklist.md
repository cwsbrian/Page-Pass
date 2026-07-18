# Child App Request Gate A Checklist

## Purpose

Prove on two physical iPhones that one child app request becomes a durable
parent-managed item and that only `Earned Time` app usage consumes credit.

This checklist uses manual payload transfer so Apple token behavior is tested
without backend, pairing, APNs, or account implementation.

## Devices And Apps

Record before starting:

```text
PagePass build:
Parent device / iOS build:
Child device / iOS build:
Parent Family Sharing role:
Child Family Sharing role:
Child authorization status:

App A (Earned Time):
App B (Always Allowed):
App C (never registered):
```

Use ordinary third-party apps. Do not use Phone, Settings, or another Apple
system app for A, B, or C.

## Setup

1. Install the same PagePass Spike build on both devices.
2. On both devices, open `Legacy Controls` and tap `Cleanup Reset`.
3. On the child device, request and approve `.child` authorization if the Gate A
   status is not `Approved`.
4. Disable unrelated native Screen Time App Limits and Downtime rules that may
   interfere with A, B, or C.

Do not request `.individual` authorization on either device.

## Test 1 - Request Persists On Parent

### Child

1. Tap `1. Pick One App to Request`.
2. Select only App A, not its category.
3. Confirm `Request selection: 1 app` and the correct label/icon.
4. Tap `2. Create or Reuse Request`.
5. Transfer `Request payload` to the parent using `Share Request Payload` or
   copy/paste through the Mac.

### Parent

1. Put the payload in the parent `Request payload` field.
2. Tap `3. Import Child Request`.
3. Confirm App A's correct name/icon and `Pending` state appear.
4. Force quit and reopen PagePass.
5. Confirm App A still appears without another child picker action.
6. Import the same request payload again.
7. Confirm `Managed apps` remains `1`.

Pass evidence:

```text
Correct app label/icon: yes / no
Persists after force quit: yes / no
Duplicate import remains one item: yes / no
```

## Test 2 - Pending And Blocked Stay Locked

### Parent

1. For App A, choose `Blocked` from `Set Parent Policy`.
2. Confirm the policy version increases and a policy payload appears.
3. Transfer the full policy payload to the child.

### Child

1. Put the payload in the child `Policy payload` field.
2. Tap `5. Import Parent Policy`.
3. Tap `6. Apply at Zero Credit`.
4. Confirm App A is shielded.
5. Confirm App C is also shielded even though it was never registered.
6. Confirm PagePass itself still opens.

Pass evidence:

```text
App A blocked: yes / no
App C default blocked: yes / no
PagePass remains available: yes / no
Policy v / applied v match: yes / no
```

## Test 3 - Earned Time Debits And Re-locks

### Parent

1. Change App A to `Earned Time` without asking the child to open the picker.
2. Transfer the new full policy payload to the child.

### Child

1. Import the new parent policy.
2. Tap `6. Apply at Zero Credit`; App A must still be shielded.
3. Tap `7. Start Earned-Time Proof`.
4. Tap `8. Refresh Extension Events` until `intervalDidStart: yes`.
5. Tap `9. Add Credit After intervalDidStart`.
6. Confirm App A opens while App C remains shielded.
7. Use App A for at least 60 seconds.
8. Refresh and confirm credit changes from 120s to 60s.
9. Continue using App A until the second threshold.
10. Confirm credit reaches 0 and App A re-locks before reopening PagePass.

Pass evidence:

```text
App A unlocked with credit: yes / no
App C stayed blocked with credit: yes / no
First threshold left 60s: yes / no
Second threshold reached 0: yes / no
App A re-locked at 0: yes / no
```

## Test 4 - Always Allowed Never Debits

Repeat Test 1 with App B. On the parent:

1. Keep App A as `Earned Time`.
2. Set App B to `Always Allowed`.
3. Export and transfer the full policy.

On the child:

1. Import and apply at zero credit.
2. Confirm App A is blocked and App B opens at zero credit.
3. Start the Earned-Time proof, wait for `intervalDidStart`, and add credit.
4. Use App B for longer than 60 seconds without using App A.
5. Refresh and confirm credit remains 120s and threshold hits do not increase.
6. Use App A for 60 seconds and confirm credit then decreases.

Pass evidence:

```text
App B open at zero: yes / no
App B usage did not debit: yes / no
App A usage did debit: yes / no
```

## Test 5 - Persistent Reclassification

Without reopening the child picker, transfer and apply each transition:

```text
App A: Earned Time -> Blocked -> Always Allowed -> Earned Time
```

At zero credit confirm, in order:

```text
Earned Time = blocked
Blocked = blocked
Always Allowed = open
Earned Time = blocked until monitored credit is added
```

Pass: all transitions use the original request and every imported version is
greater than the previous version.

## Test 6 - Restart And Tamper

1. Leave App A as `Earned Time`, App B as `Always Allowed`, and credit at zero.
2. Restart the child iPhone.
3. Confirm App A remains blocked and App B remains open.
4. Attempt to delete PagePass while `.child` authorization is approved.
5. Confirm iOS prevents deletion without guardian action.
6. Start another run, add credit, force quit PagePass, and use App A to zero.
7. Confirm the monitor extension re-locks App A before PagePass is reopened.

## Stop Conditions

Stop and capture screenshots plus the visible event log if any occurs:

* parent imports one app but shows the wrong name/icon
* a policy import asks the child to use the Picker again
* Pending or Blocked opens with credit
* Always Allowed usage decreases credit
* App C opens with credit despite never being registered
* an empty Earned Time set starts a DeviceActivity event
* policy shows `applied` before the child applies it
* force quit prevents re-lock at zero

## Physical Run Result - 2026-07-15

Devices:

```text
Parent: iPhone 15 / iOS 26.5.2
Child: iPhone XR / iOS 18.7.9
Child authorization: approved
App A: Angry Birds 2 / Earned Time
App B: Notes / Always Allowed
Safari: explicitly registered / Blocked
Final policy version: v4
```

Observed results:

```text
App request rendered the correct name and icon on the parent: pass
Request persisted after force quit: pass
Duplicate request import remained one item: pass
Parent reclassified the original request without reopening the picker: pass
Pending and Blocked stayed shielded: pass
Notes opened at zero and did not debit Earned Time credit: pass
Angry Birds credit changed 120 -> 60 -> 0: pass
Both cumulative thresholds were registered before monitoring began: pass
Angry Birds re-locked at zero before PagePass reopened: pass
Safari stayed blocked while Angry Birds had credit: pass
```

The second threshold was observed in the App Group state with
`thresholdReachedCount = 2`, `creditSeconds = 0`, and `isShielded = true`.
During the Notes negative control, credit remained 120 and no new threshold
event appeared.

Safari finding:

* `.all(except:)` category shielding did not shield Safari.
* Explicitly adding the Safari `ApplicationToken` to `shield.applications`
  did shield Safari on the XR.
* Apple documents the system-app exception as intentional behavior. Safari
  therefore requires mandatory token enrollment plus a bundle-ID fail-safe.

Not yet run:

* Test 5 full four-state reclassification sequence
* Test 6 restart, deletion resistance, and force-quit run
* `Application(bundleIdentifier: "com.apple.mobilesafari")` physical fallback
  probe

Gate A verdict: the child-request-to-parent-policy control loop, selective
unlock, earned-only debit, quantized consumption, and automatic re-lock are
proven on two physical iPhones. The remaining items are hardening tests, not a
blocker for beginning the pairing/backend slice.

## Automated Regression Result - 2026-07-15

The child flow from step 7 onward was automated on the XR with the launch
argument `--pagepass-auto-managed-proof`. The driver starts a managed proof,
waits for the matching `intervalDidStart`, and only then activates credit.
State and extension events were read directly from the App Group container.

Code and runtime hardening added during this run:

* register cumulative 60-second and 120-second events together before
  `startMonitoring`; the monitor extension no longer rearms after each quantum
* reject duplicate and out-of-order callbacks without restoring or double
  debiting credit
* keep the run fail-closed if a threshold arrives before credit activation
* schedule the monitoring interval three seconds in the future; scheduling at
  the already-passed current second caused both callbacks to replay immediately
  on iOS 18.7.9

Automated physical observations:

```text
Clean run: 91E36206-DF43-4AE4-92FE-46EA156196A6
intervalDidStart -> credit 120 -> automation ready: pass
Notes foreground for 70 seconds: credit stayed 120, pass
Angry Birds at zero credit: shield state true, pass
Final threshold: credit 0 and shield state true, pass
```

Precision regression discovered under repeated monitor registration:

```text
Run 91E36206-DF43-4AE4-92FE-46EA156196A6:
  first Angry Birds launch caused cached 60s and 120s callbacks together

Retry run 4642701E-ECBA-4D45-B961-6E35F9717AE2:
  10 seconds Angry Birds: credit stayed 120
  first 60s callback: 16:41:17, after about 13 seconds measured foreground use
  second 120s callback: 16:41:59, after about 50 seconds measured foreground use
```

The callbacks used the correct run-specific names and only the Earned Time app
token. The behavior therefore is not a token-mix or reducer double-debit bug.
It is consistent with stale or coarsely reported DeviceActivity usage being
applied to newly registered events despite `includesPastActivity = false` on
the XR. The three-second future boundary fixes the registration-time replay but
does not make 60-second accounting precise after repeated runs.

Amended verdict: selective enforcement and automatic re-lock remain proven.
Exact short-interval debit is not production-proven on iOS 18.7.9 and is a
hardening blocker. Before shipping, run a realistic-duration matrix on a fresh
iOS 18 child device and a current-iOS child device, and define an explicit
fail-closed recovery for a contaminated DeviceActivity baseline.
