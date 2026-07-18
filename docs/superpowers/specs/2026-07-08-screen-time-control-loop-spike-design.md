# Screen Time Control Loop Spike Design

## Goal

Prove PagePass's riskiest product loop on a physical iPhone before building OCR, backend, AI, or parent workflows.

The spike answers one question:

```text
Can selected limited apps lock, unlock, consume earned credit through actual usage, and re-lock at zero credit?
```

## Non-Goals

This spike does not build:

* Backend
* Auth
* Parent app
* OCR
* AI Review
* Polished UI
* App Store copy
* Subscription

## Required Device Conditions

The test must run on a physical iPhone. Simulator verification is not enough because the core behavior depends on Apple's Screen Time APIs.

Required APIs:

* `FamilyControls`
* `ManagedSettings`
* `DeviceActivity`

Required Apple setup:

* Family Controls entitlement for the app target
* App target provisioning profile includes Family Controls, DeviceActivity/ManagedSettings access required by the SDK, and App Group
* DeviceActivity monitor extension entitlement and embedded extension target
* Monitor extension provisioning profile includes its required Screen Time capability, DeviceActivity monitor extension support, and App Group
* App Group entitlement enabled for both the app and extension
* Development signing profiles that include every entitlement above
* Physical child test device signed into a child Apple ID in a Family Sharing group
* Guardian approval flow available for `requestAuthorization(for: .child)`
* Apps installed on the child device that can be selected as limited apps
* No web-domain monitoring in this spike; App Website Usage support is deferred until a separate web-domain spike

Use these identifiers. If any identifier is unavailable in the Apple Developer portal, update this spec with the replacement before implementation continues:

```text
App bundle id: com.pagepass.controlspike
Monitor extension bundle id: com.pagepass.controlspike.DeviceActivityMonitor
App Group id: group.com.pagepass.controlspike
ManagedSettings store name: PagePassControlSpike
DeviceActivity name prefix: PagePassCreditRun
DeviceActivity event name prefix: limitedAppCredit
```

Each credited run must use run-specific names:

```text
DeviceActivity name: PagePassCreditRun-<run id>
DeviceActivity event name: limitedAppCredit-<run id>
```

Before every physical test run:

```text
Stop all old PagePassCreditRun monitors.
Clear the PagePassControlSpike ManagedSettings store.
Reset shared App Group state and logs.
Disable unrelated iOS Screen Time settings that could interfere with the selected app, including Downtime, App Limits, and Always Allowed exceptions.
Record device model, iOS version, build number, child Apple ID status, and selected app token counts.
```

## App Shape

Create a minimal iOS app named `PagePassControlSpike`.

The app has one screen with these controls:

* Request Screen Time authorization
* Pick Limited Apps
* Lock selected apps
* Start credited run
* Run negative-control test
* Cleanup reset

The UI can be plain SwiftUI. It only needs enough state to test the loop.

## Components

### Control State

Stores local spike state:

* selected application tokens
* current credit seconds
* whether shield is currently applied
* active DeviceActivity schedule name
* current run id
* persisted event log

Use shared app group storage for state that must be read or written by both the app and the DeviceActivity extension.

Persist at minimum:

```text
selection data
credit seconds
is shielded
active run id
active activity name
active event name
monitoring interval start timestamp
monitoring interval end timestamp
event threshold seconds
schedule interval
includesPastActivity setting or SDK-unavailable note
events: event name, activity name, timestamp, source, credit before, credit after, selected application token count
```

### App Selection

Uses `FamilyActivityPicker` to select limited apps. This spike only proves application tokens. Category and web-domain selections must be rejected for the spike, because mixing token types could make the result look broader than what was actually proven.

The app does not need to know app names. It only stores Apple-provided selection tokens.

### Shield Control

Uses `ManagedSettingsStore` with the shared store name `PagePassControlSpike` to apply and clear shields from both the app and extension.

Rules:

```text
Credit = 0 -> shield selected limited apps
Credit > 0 -> clear shield for selected limited apps
Cleanup reset -> clear shield only as an explicit test cleanup override
```

### Usage Monitor

Uses a `DeviceActivityMonitor` extension with a fresh schedule and an event threshold based on test credit.

The monitor must avoid false positives from past usage:

```text
Use a fresh run id for each run.
Use run-specific DeviceActivity and event names derived from that run id.
Stop stale monitors before starting.
Set includesPastActivity to false if the SDK exposes that option.
If the SDK does not expose includesPastActivity, the run is only valid after waiting for a fresh DeviceActivity interval and recording intervalDidStart evidence for the run-specific activity.
Use a selected app that has not been opened during the active run-specific interval before credit is added.
Persist extension-written logs before mutating credit.
```

The schedule interval must satisfy the SDK minimum. Do not assume the schedule itself can be shorter than Apple's minimum interval; use the shortest valid interval and keep the event threshold small for manual testing.

Rules:

```text
Start monitoring before selected apps are unlocked
If monitoring fails to start -> keep selected apps shielded
If intervalDidStart is not observed for the run-specific activity -> keep selected apps shielded
After intervalDidStart for the run-specific activity -> add credit and unlock
If callback activity/event names do not match the active run id -> log stale callback and do not mutate credit or shields
If selected app usage reaches credit threshold -> extension fires
Extension sets credit to 0
Extension reapplies shield
```

### Local Verification Log

Keep a tiny local event log visible in the app:

```text
authorization requested
selection saved
shield applied
cleanup reset
monitoring start requested
monitoring started
interval did start
credit added
shield cleared after monitoring started
threshold reached
credit consumed
shield reapplied
stale callback ignored
negative control passed
negative control failed
```

This log is persisted in the App Group so the extension can write proof even when the main app is not running. It is for debugging only. No analytics.

## Data Flow

1. User requests authorization.
2. User confirms authorization is for `.child`, not `.individual`.
3. User picks limited apps.
4. App rejects the selection if it contains categories, web domains, or zero application tokens.
5. App saves application selection tokens locally in App Group storage.
6. Cleanup reset stops stale monitors, clears the named ManagedSettings store, and clears shared logs.
7. With zero credit, app applies shield.
8. User starts a credited run.
9. App creates a fresh run id.
10. App derives run-specific DeviceActivity and event names.
11. App starts `DeviceActivity` monitoring for selected apps.
12. App confirms monitoring started but keeps selected apps shielded.
13. Monitor extension writes `intervalDidStart` for the run-specific activity.
14. App confirms `intervalDidStart` evidence for the active run id.
15. App adds test credit and clears the shield.
16. Tester opens one selected limited app and uses it until the threshold is reached.
17. Monitor extension fires for the run-specific activity and event names.
18. Extension verifies callback activity/event names match the active run id in App Group state.
19. Extension writes an App Group event with timestamp, run id, activity name, event name, token count, and credit before/after.
20. Extension sets credit to zero and reapplies the named ManagedSettings shield.
21. Tester confirms the selected app is blocked before reopening PagePass.
22. Tester reopens PagePass and confirms the extension-written event is visible.

## Background And Force-Quit Flow

Run both variants after the foreground selected-app flow passes:

1. Cleanup reset.
2. Select one limited app.
3. Start a credited run.
4. Wait for run-specific `intervalDidStart`.
5. Add credit and unlock.
6. Background PagePass for the background variant, or force quit PagePass for the force-quit variant.
7. Use the selected app until the threshold is reached.
8. Confirm the selected app is re-shielded before reopening PagePass.
9. Reopen PagePass and confirm the extension-written event log has the matching run id, activity name, and event name.

## Negative-Control Flow

Run this after the positive selected-app flow passes:

1. Cleanup reset.
2. Select one limited app.
3. Start a credited run.
4. Wait for run-specific `intervalDidStart`.
5. Add credit and unlock.
6. Use a non-selected app for longer than the limited-app threshold.
7. Confirm the DeviceActivity threshold does not fire.
8. Confirm credit remains unchanged.
9. In the same run, use the selected app until the threshold is reached.
10. Confirm the selected-app threshold fires and consumes credit.

## Error Handling

If authorization is denied:

* show authorization denied in the event log
* disable picker, lock, credit, and monitoring controls

If no limited apps are selected:

* show no selection in the event log
* disable lock and monitoring controls

If category or web-domain tokens are selected:

* show unsupported token type in the event log
* require app-only selection before the run can start

If DeviceActivity monitoring fails to start:

* show the thrown error in the event log
* keep selected apps shielded
* do not add credit
* do not clear the shield

If threshold does not fire:

* record the test as failed
* do not proceed to backend or OCR work until root cause is understood

## Success Criteria

The spike passes only if all are true on a physical iPhone:

```text
Selected apps can be shielded.
Selected apps are unshielded only after monitoring starts, run-specific intervalDidStart is observed, and credit is added.
Actual selected app usage after the credited run starts reaches a DeviceActivity threshold.
The threshold callback fires for the run-specific activity and event names.
The callback consumes credit.
The extension writes persisted evidence before the main app is reopened.
Selected apps are shielded again at zero credit while the selected app is being used or before it can be relaunched.
The loop still works when PagePass is backgrounded before selected-app usage starts.
The scheduled monitor still fires and reapplies shields when PagePass is force quit before selected-app usage starts.
Using a non-selected app does not consume credit, and then using the selected app in the same run does consume credit.
```

Required evidence for a pass:

```text
Physical device model and iOS version
Build number and signing profile used
Authorization mode: child
Selected application token count
Selected app manually observed by tester
Non-selected app manually observed by tester
Schedule interval
Event threshold seconds
includesPastActivity value, or SDK-unavailable note plus fresh-interval evidence
Run-specific activity name and event name
intervalDidStart timestamp for the run-specific activity
Screenshot or video of initial shield
Screenshot or video of unlock after credit
Extension-written event log with timestamp and run id
Screenshot or video of re-shield after credit reaches zero
Screenshot or video proving re-shield before reopening PagePass in background and force-quit runs
```

## Failure Criteria

The spike fails if any are true:

```text
Family Controls entitlement cannot be used on device.
Authorization only works with `.individual` and not `.child`.
Selected apps cannot be reliably shielded.
Selected apps unlock before run-specific intervalDidStart is observed.
DeviceActivity threshold does not fire for selected apps.
Threshold fires for an activity/event name that does not match the active run id.
The app cannot reapply shield from the monitor callback.
Credit state cannot be shared reliably between the app and monitor extension.
Monitoring starts with empty application tokens.
Non-selected app usage consumes credit.
Negative control never proves that selected-app usage fires in the same run.
Old monitors, old logs, or unrelated iOS Screen Time settings can explain the observed shield behavior.
```

## Testing

Automated tests should cover only pure local logic:

```text
credit 0 -> locked
credit > 0 -> unlocked
monitoring started but interval not active -> stay locked and do not add credit
monitoring failure -> stay locked and do not add credit
stale callback with wrong run id -> credit unchanged and shield unchanged
threshold reached -> credit 0 and locked
non-selected app event -> credit unchanged
cleanup reset -> credit 0 and unlocked only through explicit cleanup override
```

Physical-device manual tests cover Screen Time APIs because simulator and unit tests cannot prove the real control loop.

## Implementation Order

1. Create minimal iOS app and DeviceActivity extension.
2. Configure app, extension, App Group, entitlements, signing profiles, embedded appex, extension principal class/module, and monitor extension plist.
3. Add pure state reducer and unit tests.
4. Add App Group persistence and extension-readable event log.
5. Add cleanup reset: stop old monitors, clear named ManagedSettings store, reset shared state.
6. Add `.child` authorization request.
7. Add FamilyActivityPicker with app-only selection validation.
8. Add ManagedSettings shield apply/clear through the named store.
9. Add credited run flow: start monitoring first, wait for run-specific intervalDidStart, then add credit, then unlock.
10. Add DeviceActivity monitoring with run-specific names and documented no-past-activity handling.
11. Add extension callback validation for active run id, activity name, and event name.
12. Add extension callback to write proof, consume credit, and reapply shield.
13. Add negative-control manual test followed by selected-app positive proof in the same run.
14. Add background and force-quit manual test variants.
15. Run physical-device checklist.
