# iOS 18 Long-Duration DeviceActivity Report

Report updated: 2026-07-17 07:12 PDT

Raw capture paths in this report are provenance references governed by
[`EVIDENCE_POLICY.md`](EVIDENCE_POLICY.md); the referenced artifacts are not
stored in Git.

## Executive Verdict

The PagePass Shield control loop is technically viable on the tested iPhone XR:

1. explicit app tokens can be persisted;
2. zero credit applies a physical Shield;
3. granting credit removes the Shield;
4. a DeviceActivity callback can debit and fail closed while the host app is
   not foreground;
5. callback persistence, ownership checks, and physical Shield recovery can be
   made crash-safe.

Target-app-only automatic debit is now **proved for FC Mobile on this same
XR/iOS 18.7.9 device**, including a second registration using the same selected
app token. It remains **unproved and unsafe for Angry Birds 2**, which repeatedly
delivered a 600-second event only seconds after activation following a long
non-target interval.

The decisive A/B tests used one exact 300-second event and SpringBoard's
automatic foreground timestamps. In r59, FC Mobile stayed non-frontmost for
324.937 seconds without a callback, then required 305.077 seconds of actual
foreground time. In r60, a new activity reused the same FC token and again
required 304.122 seconds of FC foreground time. Both event readbacks contained
one explicit application token, no category or web-domain tokens,
`includesAllActivity=false`, and `includesPastActivity=false`.

Those results disprove a generic registration-time wall clock, a generic
same-token carry-over failure, and a generic XR/iOS 18.7.9 inability to measure
selected apps. Earlier Angry runs remain valid evidence of an app/token-specific
failure or another unisolated Angry-specific condition. Stale PagePass parent
policy is ruled out for r58-r60: their captured App Group plists contain no
`managedApps` or managed-policy keys, and the automation path builds its event
directly from the current local Picker selection. Because PagePass cannot read
the system accumulator or validate the callback's underlying usage, automatic
debit is not yet production-safe for arbitrary selected apps. The next gate is
an interruption/resume test with FC Mobile plus the same protocol on at least
one additional third-party app.

r61 then removed the long non-target phase for Angry Birds. Angry was launched
only 7.792 seconds after `intervalDidStart`. The 300-second callback arrived
293.030 seconds after Angry became foreground but 300.822 seconds after
`intervalDidStart`. This rejects a pre-existing 300-second baseline as the
simple explanation: the current Angry event counted the short in-run non-target
gap. No browser or target foreground transition occurred in that gap.

r62 repeated the Angry test after revoking Family Controls authorization,
uninstalling PagePass, rebooting the XR, reinstalling the signed app, granting
fresh `.child` authorization, and selecting Angry again. The callback arrived
299.334 seconds after `intervalDidStart`, but only 227.926 seconds after Angry
became foreground. The preceding 71.408 seconds contained no Angry foreground
transition. This rules out PagePass's installed container, persisted policy,
and prior authorization generation as the source of the Angry wall-clock
accounting. It does not prove that iOS's private Screen Time activity store was
reset by those actions.

r63-r66 narrowed the result further. A single 600-second event containing
Angry and FC (r63) again fired at 601.798 seconds from interval start after only
286.015 seconds of Angry foreground. A diagnostic configuration with two
independent events in one activity (one app token per event, r64) then measured
both apps correctly: Angry fired after 603.866 seconds of Angry foreground and
FC fired after 602.957 cumulative foreground seconds across an interruption.
That diagnostic disabled debit and Shield callback side effects.

The r64 result did not normalize the token permanently. After the subsequent
aggregate diagnostic, r66 returned to one Angry-only 600-second event. It fired
601.371 seconds after `intervalDidStart` but only 286.796 seconds after Angry
became foreground; the preceding 314.575 seconds had no selected-app foreground
transition. This is the cleanest reproduction of the current-interval wall-clock
pattern after the apparently correct r64 measurement. The evidence therefore
does not support one deterministic explanation such as stale PagePass state,
aggregate-token summing, or a universally broken Angry token.

r67-r70 then repeated the disputed topology under one immutable build in A-B-B-A
order. A registered two singleton events (Angry and FC); B registered one Angry
singleton event. Every run used observer-only callbacks, the exact captured
token bytes, zero grace, about 300 seconds Home, and SpringBoard foreground
timestamps. All four runs fired at about 600 seconds from interval start after
only 285.576 to 287.071 seconds of Angry foreground. Event count did not predict
the outcome. r64 is therefore an unreproduced target-accurate outlier, not
evidence for a per-app event workaround. Opaque iOS Screen Time state or run
history remains the leading boundary that PagePass cannot inspect.

r74 repeated the production-shaped singleton test with the previously verified
FC Mobile token and an exact 600-second event. Home remained foreground for
308.301 seconds without a callback. FC then remained unlocked past five minutes
and reached the callback after 602.084 seconds of FC foreground time. This third
FC pass directly answers the Home 5 min -> FC test: Home did not consume FC's
budget, FC did not lock at five minutes, and it locked at approximately ten
minutes. An earlier r71 attempt was invalid because a token was extracted from
the unordered JSON encoding of a two-token `Set`; readback proved that run had
registered Angry Birds rather than FC Mobile. r74 used the canonical FC-only
r59 selection and verified exact device readback before starting.

## Test Duration

The evidence campaign ran from approximately 2026-07-15 15:31 PDT through
2026-07-17 07:12 PDT, about 39 hours 41 minutes in total. This was a campaign of
multiple builds and scenarios, not one uninterrupted foreground-app run.

The latest r26 successor monitor stayed unchanged during the Notes negative
control for approximately 12,677 seconds, or 3 hours 31 minutes 17 seconds.

## Environment

| Item | Value |
| --- | --- |
| Child device | iPhone XR (`iPhone11,8`) |
| OS | iOS 18.7.9 (`22H355`) |
| CoreDevice ID | `ECD4AC42-2A15-5EBB-AE42-98CE87A89F95` |
| Hardware UDID | `00008020-00192D321A21002E` |
| App | `com.pagepass.controlspike` |
| Monitor extension | `com.pagepass.controlspike.DeviceActivityMonitor` |
| App Group | `group.com.pagepass.controlspike` |
| Authorization | Family Controls child authorization approved |
| Compared app tokens in legacy proof mode | Angry Birds 2 (`com.rovio.baba`), FC Mobile (`com.ea.ios.fifamobile`) |
| Negative-control app | Notes (`com.apple.mobilenotes`) |
| Event policy | Explicit application token, `includesPastActivity=false` |
| r26 logical quantum | 900 seconds |
| r26 measurement grace | 60 seconds on every one-shot quantum |
| r26 physical threshold | 960 seconds |
| Schedule | Absolute, non-repeating, four-hour interval |

## Case Matrix

| Case | Expected | Observation | Result |
| --- | --- | --- | --- |
| Child authorization | Approved locally | Approved and enforcement APIs worked | Pass |
| Explicit app selection | Application token count is 1 | Angry Birds token persisted; app name/icon resolved | Pass |
| Zero-credit lock | Earned app is shielded | Angry Birds physically shielded | Pass |
| Credit grant | Earned app unlocks | Shield removed after credit activation | Pass |
| Host app backgrounded | Extension still debits | Callback and debit occurred without PagePass foreground | Pass |
| Stale callback | Must not mutate active run | Stale interval-end callback was logged and ignored | Pass |
| First r26 quantum | No debit before at least 900 seconds of target use | Debit observed at 954.258 seconds after host launch request | Inconclusive; host timestamp superseded |
| First r26 debit | 1800 -> 900, one hit | Exactly 1800 -> 900, hit count 0 -> 1 | Pass |
| Fail-closed handoff | Shield before successor commit | Shield confirmation followed threshold by 0.006 seconds | Pass |
| Fresh successor | New run and interval start | New run ID armed and started about 2.238 seconds later | Pass |
| Notes negative control | Credit remains 900 | 900 remained unchanged for about 3h31m | Pass for no callback, not proof of target isolation |
| r26 second target quantum | 900 -> 0 after target use | Not executed after harness stopped | Incomplete |
| r26 final Shield | Zero credit physically relocks | Not reached in r26 | Incomplete |
| Exact stopwatch behavior | Foreground use maps exactly to elapsed seconds | Historical callbacks varied materially | Not proved |
| r40 cumulative 60 s cadence | Notes must not advance Angry thresholds | Notes stayed stable, then 180 s callback arrived before 120 s after resume | Fail |
| r40 single final event | Only Angry foreground time reaches 180 s physical threshold | Fired after Angry 60 s + Notes 90 s + Angry 28 s | Fail |
| r41b system-timed 10-minute control | Notes excluded; at least 600 s Angry use before debit | Notes 619.343 s; callback after 31.804 s Angry and 659.442 s from interval start | Fail |
| r42 normalized threshold | Normalized 11-minute event changes any malformed-duration behavior | Notes 617.730 s; callback after 27.970 s Angry and 659.534 s from interval start | Fail |
| r43 system registration readback | System-retained event exactly matches requested app-only event | Exact dictionary match; app 1, category/web 0, all-activity false, threshold 11 m | Pass |
| r59 fresh FC token, non-target interval | Non-target wall time must not count; FC must require about 300 s foreground | FC non-frontmost 324.937 s with no callback; callback after 305.077 s FC foreground | Pass |
| r60 reused FC token | A second registration must not inherit prior FC usage | FC non-frontmost 64.333 s with no callback; callback after 304.122 s FC foreground | Pass |
| r61 Angry immediate launch | Callback should require about 300 s Angry foreground | Callback after 293.030 s Angry, exactly 300.822 s after interval start | Fail |
| r62 Angry after app/auth reset | Revoke, uninstall, reboot, reinstall, and fresh selection must clear PagePass-local contamination | Callback after 227.926 s Angry and 299.334 s from interval start; 71.408 s pre-target gap counted | Fail |
| r63 Angry + FC aggregate event | A 600 s aggregate event must require 600 s selected-app foreground | Callback after 286.015 s Angry and 601.798 s from interval start | Fail |
| r64 independent per-app diagnostic events | Each 600 s event must track only its own app across interruption | Angry 603.866 s; FC cumulative 602.957 s | Pass, diagnostic only |
| r65 aggregate sequence | Home 300 s + Angry 300 s + FC 300 s should not lock before 600 s selected foreground | User transition interrupted the planned flow; callback followed after 455.308 s observed selected foreground | Fail, but not a clean sequence |
| r66 Angry-only after r64 | A fresh 600 s Angry event must ignore 5 min Home | Callback after 286.796 s Angry and 601.371 s from interval start | Fail |
| r67 A1, two singleton events | Reproduce r64 with one immutable build | Home 302.322 s; callback after 286.515 s Angry and 601.401 s from interval start | Fail |
| r68 B1, one singleton event | Same build with only event count/token-set shape changed | Home 302.189 s; callback after 287.071 s Angry and 600.278 s from interval start | Fail |
| r69 B2, one singleton event repeat | Same B cell must reproduce | Home 302.653 s; callback after 286.360 s Angry and 599.400 s from interval start | Fail |
| r70 A2, two singleton events repeat | Returning to A must reproduce r64 if topology is causal | Home 302.918 s; callback after 285.576 s Angry and 602.231 s from interval start | Fail |
| r71 FC attempt | Home 5 min must not consume a 600 s FC event | Device readback showed the selected token was Angry, not FC, due unordered two-token JSON extraction | Invalid |
| r74 FC-only Home control | Home 5 min must not consume FC budget; FC should lock near 10 min, not 5 min | Home 308.301 s with no callback; FC remained unlocked past 5 min and callback arrived after 602.084 s FC foreground | Pass |
| Post-r66 non-destructive cleanup | Stop PagePass monitors and clear both Shield stores without reauthorization | Activity count 0; both stores clear; state unshielded; Angry token preserved | Pass |
| Final fail-closed enforcement | Invalid callback order must not leave apps open | Credit forced to 0 and Shield applied | Pass |

## System-Timed 10-Minute Validation

### Timing method

The harness starts `idevicesyslog` before launching either control app and
extracts SpringBoard lines of this form:

```text
Application process state changed for <bundle>: ... visibility: Foreground
```

These system timestamps are the only phase-start timestamps used for pass/fail.
The callback timestamp is written by the DeviceActivity monitor extension to
the shared App Group. Launch-command timestamps and screenshots are retained
only as supporting evidence.

A separate calibration showed that host launch requests preceded SpringBoard
foreground transitions by approximately 0.65 to 0.77 seconds. That delay is
real but far too small to explain a roughly 570-second target-use deficit.

### r41b: original duration representation

Evidence directory:
`docs/manual-tests/evidence/2026-07-15-ios18/system-foreground-r41b-1784211970`

| Measurement | Result |
| --- | ---: |
| Notes actual foreground control | 619.343 s |
| Credit after Notes control | 600 s |
| Callbacks after Notes control | 0 |
| Angry actual foreground to callback | 31.804 s |
| `intervalDidStart` to callback | 659.442 s |
| Physical event threshold | 660 s |

### r42: normalized duration representation

Evidence directory:
`docs/manual-tests/evidence/2026-07-15-ios18/system-foreground-r42-normalized-1784212939`

| Measurement | Result |
| --- | ---: |
| Registered threshold prepared by app | 0 h 11 m 0 s |
| Notes actual foreground control | 617.730 s |
| Credit after Notes control | 600 s |
| Callbacks after Notes control | 0 |
| Angry actual foreground to callback | 27.970 s |
| `intervalDidStart` to callback | 659.534 s |
| Physical event threshold | 660 s |

The repeatability is decisive for the selected Angry Birds token and those
runs: changing the duration representation did not change behavior, while
callback timing remained locked to schedule elapsed time rather than observed
Angry foreground time. The later FC Mobile A/B prevents generalizing this
behavior to all application tokens or to DeviceActivity on this XR as a whole.

### r43: system registration readback

After `startMonitoring`, the app fetched the system's static event
representation with `DeviceActivityCenter.events(for:)` and required exact
equality with the requested event. The readback was:

```text
applications=1; categories=0; web domains=0;
includesAllActivity=false; threshold=0h11m0s
```

The monitoring token exactly matched the token classified `.earnedTime` by
PagePass `ManagedAppPolicy` in that historical run. Notes was classified
`.alwaysAllowed` by PagePass. These are PagePass policy labels, not Apple Screen
Time settings; the later r58-r60 legacy runs did not use that managed policy.
App and monitor extension signatures both contain Family Controls and the same
App Group entitlement.

### Interpretation boundary

Apple documents activity as time the specified application, category, or web
domain is frontmost. The observed wall-clock-shaped result contradicts that
contract. Apple Developer Forums also contain reports of overcounting on iOS
17.6.1/iOS 18 and premature callbacks on later iOS releases. Those reports
support platform risk but do not prove the root cause of this exact device.

The remaining plausible causes are narrower after r59/r60:

1. Angry Birds-specific Screen Time classification or opaque-token state;
2. an Angry-specific associated-domain or activity-classification interaction
   not exposed by the event readback;
3. an app-dependent DeviceActivity defect on iOS 18.7.9.

Manual launch timing, screenshots, threshold component normalization, an empty
event, category selection, mismatched policy tokens, missing entitlements, a
generic schedule wall clock, generic same-token registration carry-over, and a
stale imported PagePass parent policy are ruled out by the captured evidence.
Other Angry-specific framework paths are not.

Primary references:

- [DeviceActivityEvent](https://developer.apple.com/documentation/deviceactivity/deviceactivityevent?changes=_3%2C_3)
- [includesPastActivity](https://developer.apple.com/documentation/deviceactivity/deviceactivityevent/includespastactivity?changes=_1)
- [DeviceActivityCenter events(for:)](https://developer.apple.com/documentation/deviceactivity/deviceactivitycenter/events%28for%3A%29)
- [Apple Developer Forums: DeviceActivityMonitor overcounting reports on iOS 17.6.1 and iOS 18](https://developer.apple.com/forums/thread/763542)

## Earlier r40 Follow-up

These shorter tests first exposed the failure pattern, but their phase timing
used host-side operations. They are supporting evidence only; the r41b/r42
SpringBoard-timed runs above supersede them for the final verdict.

### Cumulative three-event run

Evidence directory:
`docs/manual-tests/evidence/2026-07-15-ios18/cumulative-r40-1784209687`

Configuration: 180 seconds credit, 60-second quantum, 60-second one-time grace,
logical events `[60, 120, 180]`, physical events `[120, 180, 240]`.

- Angry foreground: first callback at 120 seconds; `180 -> 120`, hit 1.
- Notes foreground for 150 seconds: state stayed `120`, hit 1.
- Angry resumed: the 180-second logical event arrived before the expected
  120-second logical event.
- Event log: `Expected cumulative threshold 120s but received 180s`.
- PagePass correctly failed closed: credit 0, Shield on, active run cleared.

This invalidates cumulative minute events on the tested device. Catching up the
future event would merely hide the ordering failure and debit credit early.

### Single final-event run

Evidence directory:
`docs/manual-tests/evidence/2026-07-15-ios18/single-interruption-r40-1784210198`

Configuration: 120 seconds credit, one logical event, 60-second grace, one
physical threshold at 180 seconds.

- Angry foreground first phase: 60 seconds, no callback.
- Notes foreground: 90 seconds, no callback while Notes remained open.
- Angry resumed: callback and final Shield appeared after 28 seconds.
- Extension interval start: `805903005.112857`.
- Threshold callback: `805903186.168670`.
- Interval-to-callback delta: 181.056 seconds.

The phase sum was approximately 178 seconds plus launch overhead, matching the
180-second schedule elapsed time rather than 180 seconds of Angry foreground
use. A longer quantum would only delay how often this wrong total is committed;
it would not make the measurement app-specific.

## Latest r26 Run

Evidence directory:
`docs/manual-tests/evidence/2026-07-15-ios18/final-r26f-1784190781`

Automation identity:

| Field | Value |
| --- | --- |
| Lease | `goal-20260716-final-r26f` |
| Generation | `final-r26f-1784190781` |
| Initial run | `B5700686-3042-4743-B36F-81085428178A` |
| Successor run | `FAC1577B-882A-49E4-9ABC-AEE4CB54B332` |

### First Quantum Timing

| Event | Foundation timestamp | Delta |
| --- | ---: | ---: |
| Initial interval started | `805883598.984927` | 0 s |
| Angry launch request | approximately `805883605.000000` | +6.015 s |
| Threshold callback | `805884559.258279` | +960.273 s from interval start |
| Shield confirmed | `805884559.264649` | +0.006 s from callback |
| Successor armed | `805884559.812856` | +0.555 s from callback |
| Successor interval started | `805884561.495920` | +2.238 s from callback |

The callback was observed by the external sampler at elapsed second 960. The
event timestamp itself was 954.258 seconds after the launch-request timestamp.
That appeared to satisfy the 900-second logical floor plus a 60-second grace.
However, the launch request is not a system foreground timestamp, and the
later r41b/r42 results show callbacks tracking interval elapsed time. This run
therefore cannot prove that 900 seconds of Angry foreground usage occurred.

The six-second difference between interval start and explicit Angry launch is
evidence that host operations are not a precise application stopwatch. The
system-timed protocol replaces this method; grace must not be used to conceal
non-target time being counted.

### Successor and Notes Negative Control

The successor monitor had all of the required clean-generation properties:

- new run, activity, and event names;
- `includesPastActivity=false`;
- a 900-second logical threshold plus 60-second measurement grace;
- `intervalDidStart=true` before unlock;
- `monitoringCompromised=false`;
- no pending debit or rearm marker.

Notes was launched after the successor had already started. The old harness
required Notes to become foreground before the successor schedule start. That
was impossible to guarantee because the extension started the successor about
two seconds after the callback, while copying App Group state over USB and
launching Notes took longer. The harness wrote:

`Notes was not foreground before the successor schedule started`

That is a harness failure, not an app failure. The few seconds in which Angry
Birds remained foreground are legitimate target-app usage and should count.
The harness has been corrected to record a carryover bound and adjust the next
timing assertion instead of rejecting the run.

After Notes became foreground, the successor state remained unchanged through
the final direct device capture at 05:20:42 PDT:

```json
{
  "creditSeconds": 900,
  "isShielded": false,
  "thresholdReachedCount": 1,
  "activeRunID": "FAC1577B-882A-49E4-9ABC-AEE4CB54B332",
  "monitoringCompromised": false,
  "thresholdDebitPending": false
}
```

At the time, this appeared to be strong evidence that Notes did not consume
Angry Birds credit. The later system-timed tests show why that inference was
unsafe: a non-target app can remain active without a callback, while the
selected app's next foreground activation delivers a callback tied almost
exactly to schedule elapsed time.

## Historical Scenarios

These runs explain why r26 uses rolling one-shot monitors and per-quantum grace.

| Scenario | Measured result | Interpretation |
| --- | --- | --- |
| Notes foreground while Angry monitored | Credit stayed 3600 for 1217 s | Non-target app did not immediately debit |
| Angry continuous with cumulative thresholds | 900/1800/2700/3600 callbacks at 857/1756/3015/3556 s | Cumulative multi-event timing was unstable |
| Angry, terminate, Notes, Angry resume | Second debit appeared by 237 s after resume | Prior design had successor contamination |
| Rolling v12 | First callback correct; successor stayed shielded | Extension-local authorization read `.notDetermined` |
| Rolling v16 first quantum | Callback after 963.006 s | First one-shot timing acceptable |
| Rolling v16 Notes control | 900 stayed unchanged for 1054 s | Negative control passed |
| Rolling v16 Angry resume | Remaining 900 consumed after about 23 s | Old successor design failed |
| r26e | Callback 963.227 s after interval start | Timing correct, but initial foreground baseline was contaminated |
| r26f | Callback 960.273 s after interval start; 954.258 s after launch request | Cleanest first-quantum result |
| r26f Notes control | 900 unchanged for about 3h31m | Strongest negative-control result |

The old v16 result remains valid evidence that the former implementation was
unsafe. It is not evidence that the current r26 successor fails, because r26
changed generation handling, recovery ordering, and grace behavior. Conversely,
r26 cannot be called a complete success until its second target quantum runs.

## Harness Iterations

The final automation attempts had several infrastructure failures before r26f:

| Attempt | Outcome |
| --- | --- |
| `final-r26` | zsh local-variable initialization failed |
| `final-r26b` | App Group copy briefly exposed stale ownership |
| `final-r26c` | `jq -e` treated valid boolean `false` as command failure |
| `final-r26d` | Trace confirmed the same boolean parsing problem |
| `final-r26e` | Real callback was correct relative to interval start, but Angry was already foreground at baseline |
| `final-r26f` | App behavior passed first quantum and long Notes control; harness rejected an invalid pre-schedule Notes condition |

These attempts must not be counted as six product failures. They were used to
harden the measurement harness and isolate the one meaningful product risk.

## Code Hardening Completed

The installed r26 build includes:

1. unique one-shot run, activity, and event identities for every quantum;
2. absolute non-repeating schedules and `includesPastActivity=false`;
3. a 60-second measurement grace on the initial and successor quanta;
4. Shield-before-commit behavior at threshold boundaries;
5. a persisted threshold marker for exactly-once crash recovery;
6. compare-and-swap ownership using both lease and nonce;
7. stale callback rejection;
8. fresh-generation recovery for missing monitors;
9. unlock only after `intervalDidStart`;
10. bounded handling of transient authorization `.notDetermined` in the host;
11. policy and token snapshot validation under the App Group lock.

## Adversarial Review and Automated Verification

Repeated adversarial rounds found and drove fixes for grace inconsistency,
crash windows around physical Shield application, lease-only ownership checks,
transient authorization handling, successor baseline contamination, stale-run
startup, and final ownership rechecks.

The earlier immutable source review returned `BLOCKER-FREE` for the declared
control-loop scope where Family Controls authorization remains approved. After
r60, two independent final reviews also returned `BLOCKER-FREE` for the next
physical-test harness. That harness now records its own hash, installed app and
monitor executable hashes, policy-state assertions, exact foreground evidence,
and both sides of the non-target/target timing boundary.

Latest verification results:

- simulator tests: 65 passed, 0 failed;
- r66 signed physical-device Debug build and embedded extension validation:
  passed;
- post-r66 Cleanup Reset readback: no PagePass activities, both Shield stores
  clear, initial unshielded state persisted, and one Angry token preserved;
- temporary test instrumentation removed; restored signed product build
  installed over the XR without launching a new run;
- app and extension entitlements: Family Controls and the shared App Group are
  present;
- normalized duration and system-registration readback builds passed signing
  and embedded-extension validation;
- the r43 build was installed on the XR and its registration readback matched.

## Current Physical State

After r66, an automated non-destructive Cleanup Reset was run while the user was
unavailable to reauthorize. It did not revoke authorization or uninstall the
app. API readback and persisted state showed:

- credit: 0 seconds;
- Shield: off;
- PagePass `DeviceActivityCenter` activities: 0;
- primary and legacy `ManagedSettingsStore` Shield values: clear;
- threshold hits: 0;
- active run: none;
- interval started: false;
- selected applications: one Angry Birds token preserved;
- authorization: not revoked or requested again.

Evidence:
`docs/manual-tests/evidence/2026-07-16-ios18/post-r66-cleanup/verified-after-cleanup-2.plist`.

## Final Product Decision

### Force-Terminated Target Isolation (r47)

The r47 run removed target-process background execution as a possible cause of
the overcount:

1. a fresh persistent meter registered one Angry Birds application token, zero
   category tokens, zero web-domain tokens, and
   `includesPastActivity=false`;
2. Angry Birds was system-foreground for 128.690 seconds;
3. `devicectl` delivered `SIGKILL` to PID 7481 and SpringBoard reported
   `Application process state changed for com.rovio.baba: (null)`;
4. Notes was launched for a 616.125-second wall-clock phase while state remained
   at 600 seconds of credit and zero threshold callbacks; an App Switcher action
   briefly returned Angry Birds to foreground for about 2.5 seconds, so this was
   not a continuous 616.125-second Notes foreground interval;
5. reopening Angry Birds delivered the 600-second threshold callback after
   only 2.937 additional seconds.

The harness calculated 131.627 seconds from its first-foreground timestamps,
not the accepted 600 to 660 seconds. That value is approximate because the
harness did not integrate every foreground/background transition. The App
Switcher card remaining visible after `SIGKILL` was only a retained recent-app
snapshot; it did not represent a live process.

The force-kill evidence rules out continuous Angry Birds process execution.
However, r47 cannot establish DeviceActivity accounting correctness because it
reused the same persisted application token after Family Controls authorization
was revoked and granted again. Apple documents that revocation voids every token
issued by the previous authorization. The r45, r46, and r47 token fingerprints
were all `68a448033d1b70558ee9568ad5b6897b1771aab3efc43743ecbe304f9abe4e7b`.
PagePass restored that void token from App Group storage instead of requiring a
fresh Picker selection. Registration readback only proved that one opaque value
was stored; it did not prove that the value was valid in the new authorization.

Evidence:
`docs/manual-tests/evidence/2026-07-16-ios18/persistent-forcequit-r47-1784222239`.

The persistent cumulative-meter experiment stopped after this invalid
first-grant run, so it did not establish either first- or second-grant behavior.
It must be repeated after cleanup and a fresh Picker selection within the
current authorization generation.

### Clean Persistent Meter (r50)

r50 removed the revoked-token defect: the XR completed Revoke Authorization,
Request Child Authorization, and a fresh Angry Birds Picker selection before
the meter was registered. One activity contained the cumulative 600- and
1200-second events, each with one application token, no category or web-domain
tokens, and `includesPastActivity=false`.

Angry Birds was foreground for 132.303 seconds and then force-terminated. Notes
was foreground for 630.520 seconds without changing the 600-second credit or
hit count. Reopening Angry Birds delivered the 600-second callback after only
12.283 seconds. Total observed Angry foreground was 144.586 seconds, far below
the configured 600-second threshold. Because this run changed both the event
count and the interruption pattern relative to r45, it proved a real failure
but did not isolate multi-event registration as the cause.

Evidence:
`docs/manual-tests/evidence/2026-07-16-ios18/persistent-clean-auth-r50-resume-1784226764`.

### Single Event With Foreground SIGKILL (r51)

r51 isolated the interruption variable while keeping exactly one 600-second
event and no measurement grace:

1. SpringBoard confirmed Angry Birds foreground for 124.639 seconds;
2. `devicectl` sent `SIGKILL` while Angry Birds was still foreground, and
   SpringBoard confirmed the process became null;
3. Notes remained foreground for 632.926 seconds while state stayed at
   `credit=600`, `hit=0`, and no Angry foreground transition was observed;
4. reopening Angry Birds delivered the only threshold callback after 9.050
   seconds, versus a conservative expected floor of 470.361 seconds.

This reproduces the early callback without a multi-event dictionary. The
evidence therefore rejects “multiple events are the demonstrated root cause.”
It instead identifies foreground SIGKILL as an experimental confound or an iOS
accounting edge case: no callback is delivered during Notes, but the selected
app's next activation causes the system to settle a threshold that includes
far more than observed selected-app foreground time.

Evidence:
`docs/manual-tests/evidence/2026-07-16-ios18/single-event-interruption-r51-1784228197`.

### Single Event With Normal Background Then Termination (r52)

r52 used a new authorization generation and fresh Angry Birds Picker token. It
registered one exact 600-second event, used Angry Birds for 124.275 seconds,
then launched Notes normally. System logs confirmed Angry transitioned through
`running-active-NotVisible` to `running-suspended-NotVisible` before PID 8085
was terminated. A resumed Notes negative control then held `credit=600` and
`hit=0` for 646.868 seconds.

When Angry Birds was opened again, it appeared already shielded to the tester.
SpringBoard recorded Angry visible at 12:32:21.845262 and the extension
persisted the threshold callback at 12:32:25.540346, a 3.695-second delivery
gap entirely inside the relaunch/loading experience. This must not be described
as 3.695 seconds of usable Angry time; observed usable time was effectively
zero.

The result shows that foreground SIGKILL is not required. Terminating the
selected process after a confirmed normal background/suspend transition still
caused the threshold to be considered satisfied or settled on the next target
activation. The API exposes no live accumulator, so the evidence cannot
distinguish whether non-target wall time was counted internally or whether
termination left the earlier selected-app session unclosed. Either behavior is
unsafe for PagePass automatic debit.

Evidence:
`docs/manual-tests/evidence/2026-07-16-ios18/single-event-background-r52-1784229270`.

### Single Event With Normal Suspend/Resume and No Termination (r53)

r53 removed process termination entirely. It used another fresh authorization
generation and Picker token, one exact 600-second application event, no category
or explicit web-domain tokens, and `includesPastActivity=false`.

Angry Birds was foreground for approximately 126.755 seconds before Notes
became foreground. Logs confirmed Angry became `running-active-NotVisible` and
then `running-suspended-NotVisible` about 1.45 seconds later.
The same Angry PID 8190 remained alive throughout the 637.818-second Notes
phase, while PagePass remained at `credit=600` and `hit=0`. The harness then
activated the already-running PID without `--terminate-existing`.

The callback was persisted 5.169 seconds after the next Angry foreground signal.
The tester initially reported Angry was already shielded, then clarified that it
may have appeared briefly before being shielded. The UI observation is therefore
inconclusive about those five seconds; the system timestamps are not. Even if all
five seconds count as usable target-app time, total observed target foreground
before the callback was only roughly 132 seconds, far below 600 seconds.

This removes multi-event registration, monitor replacement, token revocation,
foreground kill, background kill, process relaunch, and PID change as required
causes. It also conflicts with Apple's documented definition of Device Activity
as the amount of time the selected application, category, or web domain is
frontmost. The remaining observed behavior on the XR/iOS 18.7.9 is: after a
selected-app foreground session begins, the event behaves as though unrelated
elapsed time can satisfy the threshold, while callback delivery waits until the
selected app becomes active again.

One harness variable remains: the foreground transitions were requested through
`devicectl process launch`. RunningBoard showed ordinary visible, background,
suspended, and same-PID resume states, so this is unlikely to explain the error,
but a final XR run must use only manual icon taps. Selecting a different
third-party app for that run also removes an Angry Birds-specific associated
web-domain hypothesis.

Evidence:
`docs/manual-tests/evidence/2026-07-16-ios18/single-event-suspend-resume-r53-1784230680`.

### Manual Icon Transitions With User Force Quit (r54)

r54 removed `devicectl process launch` from every selected-app transition. It
used a fresh authorization generation and Picker token, one application token,
one exact 600-second event, no categories or explicit web domains, and
`includesPastActivity=false`. DeviceActivityCenter readback again matched the
request: `applications=1`, `categories=0`, `web domains=0`,
`includesAllActivity=false`, and threshold 10 minutes.

The tester opened Angry Birds from its Home Screen icon and used it for 121.770
seconds. They then opened Notes from its icon and manually force-quit Angry Birds
from the app switcher. During more than 600 seconds of Notes foreground time,
PagePass remained at `credit=600`, `shielded=false`, and `hit=0`; the unshielded
Angry Birds icon remained visible on the Home Screen.

The tester then opened Angry Birds again from its Home Screen icon. SpringBoard
reported the new PID 8399 as `running-active-Visible` at 13:23:00.338620. The
matching 600-second threshold event was persisted 4.013 seconds later, changing
credit from 600 to 0 and applying the shield. Given the first 121.770 seconds of
target foreground, the callback should not have occurred for at least another
473.230 seconds under the probe's five-second tolerance.

This confirms that Mac-driven app activation was not required for the early
callback. The observed UI sequence also matches the state timeline: the icon was
not shielded while the callback was pending; reopening the selected app caused
the system to deliver the callback and PagePass then applied the shield. r54
includes a user force quit, while r53 independently reproduced the same class of
failure with the original selected-app process suspended and alive. Together,
the runs leave DeviceActivity accumulation or baseline handling on this
XR/iOS 18.7.9 environment as the leading explanation.

Evidence:
`docs/manual-tests/evidence/2026-07-16-ios18/single-event-manual-r54-1784232305`.

### No Target Session Before First Callback (r55)

r55 tested whether an earlier selected-app foreground session was required to
leave an internally open usage timer. It reused r54's still-authorized Picker
token but created a new activity, run ID, event name, absolute schedule, and
exact 600-second threshold with `includesPastActivity=false`. Registration
readback again showed one application, no categories, no explicit web domains,
and `includesAllActivity=false`.

After `intervalDidStart`, the selected Angry Birds app was not foregrounded at
all. Notes remained foreground for 646.757 seconds. Through the complete
negative-control phase, PagePass remained at `credit=600`, `shielded=false`, and
`hit=0`.

The harness then launched Angry Birds for the first time in this monitoring run.
SpringBoard reported PID 8458 foreground at 13:41:44.596792. The matching
600-second threshold event was persisted only 3.677 seconds later and changed
credit from 600 to 0. Correct target-only accounting required approximately 600
additional seconds because current-run target foreground before that launch was
zero.

This rules out an earlier target foreground session in the current run as a
necessary condition. It does not yet distinguish two framework-level paths:

1. The current activity's elapsed schedule time was treated as selected-app
   activity when the selected app first became active.
2. Usage associated with the reused opaque application token survived the new
   registration despite `includesPastActivity=false`.

At this point, a fresh authorization generation and a second app were the next
discriminators. r58 later showed that reselecting Angry yields the same stable
opaque token, while r59/r60 showed correct first and second registrations for
FC Mobile. The remaining uncontrolled difference is now app/token-specific
system behavior, not an imported PagePass parent policy.

Evidence:
`docs/manual-tests/evidence/2026-07-16-ios18/no-target-before-threshold-r55-1784233842`.

### Non-target Interval With Angry Birds (r56 and r58)

r56 replaced the Notes phase with a non-target interval and used one exact
300-second event. Angry did not become foreground for 325.328 seconds and no
callback arrived. Opening Angry Birds then delivered the callback after 0.575
seconds. r58 repeated the protocol after authorization revoke, cleanup, reboot,
authorization approval, and Picker selection. Angry remained non-frontmost for
325.031 seconds, followed by a callback 5.722 seconds after Angry became
foreground.

Canonical decoding showed that reselecting Angry produced the same opaque token
as before. That is expected evidence of token stability for the same app, not a
new independent app token. The two runs disprove callback delivery while Angry
remained non-frontmost, but by themselves cannot distinguish an Angry-specific
baseline from a generic same-token registration problem.

Evidence:

- `docs/manual-tests/evidence/2026-07-16-ios18/home-idle-r56-1784235195`
- `docs/manual-tests/evidence/2026-07-16-ios18/home-idle-fresh-r58-1784236175`

### Fresh FC Mobile A/B (r59 and r60)

r59 selected FC Mobile, an app PagePass had not previously monitored. Its
canonical token hash differed from Angry Birds. One exact 300-second event was
registered and read back with one application, no category or web-domain
tokens, `includesAllActivity=false`, and `includesPastActivity=false`.

FC remained non-frontmost for 324.937 seconds without a callback. After SpringBoard
reported FC Mobile foreground, the callback timestamp arrived 305.077 seconds
later. This directly rejects the hypothesis that PagePass's event is simply a
timer from registration or interval start.

r60 then created a new run, activity, and event while reusing the same FC token.
FC remained non-frontmost for 64.333 seconds without a callback, then foreground
lasted 304.122 seconds before the callback. This rejects a generic same-token
re-registration carry-over defect. The approximately four-to-five-second
overrun is consistent across both FC runs and is small relative to the
300-second threshold; no early debit occurred.

| Run | Target non-frontmost | Target foreground to callback | Result |
| --- | ---: | ---: | --- |
| r59, first FC registration | 324.937 s | 305.077 s | Pass |
| r60, second FC registration | 64.333 s | 304.122 s | Pass |

Evidence:

- `docs/manual-tests/evidence/2026-07-16-ios18/home-idle-fc-fresh-r59-1784237214`
- `docs/manual-tests/evidence/2026-07-16-ios18/fc-baseline-reuse-r60-1784237932`

### Angry Immediate Launch (r61)

r61 tested the hypothesis that Angry already held at least 300 seconds of stale
activity before a new registration. The latest signed build was installed on
the XR and identified by executable SHA-256 values captured from the installed
bundle:

- app: `add57effbacae20c93727b649222f0f9842f2606fceb4f824a577c7303af07a8`;
- monitor: `c10913dd27fd43dbc0d0c27032f35596197f43861ac30666daf5f3961ca14979`.

The harness also proved that PagePass managed-policy keys were absent,
`enforcementMode=legacySelection`, `monitoringPolicyVersion=nil`, and the stored
selection exactly matched the monitoring selection.

| Event | Timestamp | Delta |
| --- | ---: | ---: |
| `intervalDidStart` | 15:15:13.539 | 0 s |
| Angry foreground | 15:15:21.332 | +7.792 s |
| Threshold callback | 15:20:14.361 | +300.822 s interval / +293.030 s Angry |

Angry did not lock immediately, so a fully satisfied cross-run baseline is not
the simple cause. Instead, the callback again tracked the current activity's
wall-clock duration. Even the 7.792-second preparation gap before Angry became
foreground contributed to the 300-second event. No browser, web-domain surface,
or Angry foreground transition occurred during that gap. This makes ordinary
background-process execution and implicit associated-domain foreground use
insufficient explanations.

Evidence:
`docs/manual-tests/evidence/2026-07-16-ios18/angry-immediate-r61-1784240104`.

### Angry App and Authorization Reset (r62)

r62 applied the strongest reset that is local to PagePass without changing the
family's system Screen Time configuration:

1. revoke PagePass Family Controls authorization;
2. uninstall PagePass;
3. reboot the iPhone XR;
4. reinstall the same signed app and monitor binaries;
5. grant `.child` authorization again;
6. select only Angry Birds through a fresh Picker session.

The reinstalled App Group plist contained only the fresh selection before the
run; no earlier run or policy state remained. The stored selection contained
one application token, zero category tokens,
and zero web-domain tokens. The run used `legacySelection`, contained no
PagePass managed-policy keys, had no managed monitoring policy version, and
read back `includesAllActivity=false`, `includesPastActivity=false`, and an
exact 300-second threshold. Installed executable hashes matched r61.

| Event | Timestamp | Delta |
| --- | ---: | ---: |
| `intervalDidStart` | 15:39:36.271 | 0 s |
| Angry foreground | 15:40:47.679 | +71.408 s |
| Threshold callback | 15:44:35.605 | +299.334 s interval / +227.926 s Angry |

No Angry foreground transition was logged in the pre-target interval. The
result therefore reproduces the current-interval wall-clock pattern after
removing PagePass's install and authorization state. Remaining explanations
are below PagePass's storage boundary: private Screen Time state retained by
iOS, or an app/token-specific DeviceActivity defect on this OS/device.

Evidence:
`docs/manual-tests/evidence/2026-07-16-ios18/angry-fresh-reset-r62-1784241566`.

### Aggregate and Independent Event Topology (r63 and r64)

r63 registered one 600-second event containing two explicit application tokens,
Angry Birds and FC Mobile. The event readback contained two applications, no
categories or web domains, and `includesAllActivity=false`. After 302.811
seconds without target foreground, Angry ran for only 286.015 seconds before
the callback. The callback was 601.798 seconds after interval start. Both
selected apps were Shielded by the aggregate event's normal fail-closed path.

r64 was a diagnostic contrast, not a product implementation. It registered two
event names inside one activity, with exactly one application token in each
event and a 600-second threshold for each. Callback handling logged timing but
intentionally did not debit or Shield. Results were:

| Event | Foreground accounting | Callback result |
| --- | ---: | --- |
| Angry-only event | 603.866 s Angry | Correct |
| FC-only event | 51.349 s + 551.608 s FC | Correct at 602.957 s cumulative |

This proves only that the same Angry token produced target-accurate accounting
in this one historical run. r67-r70 failed to reproduce the result with the
same event count under a controlled crossover. r64 does not prove a per-token
event workaround, and independent callbacks cannot safely debit one shared
credit pool without duplicate-charge arbitration.

Evidence:

- `docs/manual-tests/evidence/2026-07-16-ios18/angry-fc-aggregate-r63-1784242974`
- `docs/manual-tests/evidence/2026-07-16-ios18/independent-angry-fc-r64c-1784244668`

### Aggregate Sequence With User Transition (r65)

r65 restored one aggregate event and planned Home 300 seconds, Angry 300
seconds, then FC 300 seconds. The measured phases before user intervention were
304.368 seconds Angry and 150.940 seconds FC, or 455.308 seconds of observed
selected-app foreground. The user attempted to return to Angry before the FC
phase completed; Angry did not regain foreground before the Shield appeared,
and the callback followed that transition attempt by 3.340 seconds.

The callback was early relative to the observed selected foreground, but this
is not a clean 5-5-5 sequence because the manual transition changed the planned
phase. It is retained as supporting evidence only.

Evidence:
`docs/manual-tests/evidence/2026-07-16-ios18/aggregate-normalized-r65-1784247157`.

### Angry-Only Reproduction After r64 (r66)

r66 performed the requested decisive sequence with one Angry application token,
no categories or web domains, `includesAllActivity=false`, and one exact
600-second event. SpringBoard's foreground timestamp and the monitor callback
gave:

| Event | Delta from interval start |
| --- | ---: |
| `intervalDidStart` | 0 s |
| Angry foreground | +314.575 s |
| Threshold callback | +601.371 s |

Angry was foreground for only 286.796 seconds before the callback. No other
target foreground transition was recorded. The event therefore consumed the
roughly five-minute Home phase and locked Angry after roughly five minutes of
actual use, exactly as predicted before the run.

This result is especially important because it occurred after r64 measured the
same Angry token correctly. r64 did not permanently repair or normalize the
token. The later r67-r70 crossover rules out event count as a reproducible
explanation and leaves opaque system-state or run-history sensitivity.

Evidence:
`docs/manual-tests/evidence/2026-07-16-ios18/angry-post-early-lock-r66-1784250747`.

### Immutable A-B-B-A Topology Crossover (r67-r70)

The crossover directly tested the objection that r64's apparent success could
not be attributed to splitting apps into separate events. One signed app and
monitor build generated both shapes. All callbacks were observer-only, so no
debit or Shield side effect could influence a successor run. Each launch
performed a non-destructive Cleanup Reset, imported exact captured token bytes,
claimed a fresh lease and nonce, used unique run/activity/event names, verified
the complete event dictionary, waited for `intervalDidStart`, and then ran Home
for about five minutes before launching Angry.

| Run | Shape | Home | Angry to callback | Interval to callback |
| --- | --- | ---: | ---: | ---: |
| r67 A1 | Angry + FC singleton events | 302.322 s | 286.515 s | 601.401 s |
| r68 B1 | Angry singleton event | 302.189 s | 287.071 s | 600.278 s |
| r69 B2 | Angry singleton event | 302.653 s | 286.360 s | 599.400 s |
| r70 A2 | Angry + FC singleton events | 302.918 s | 285.576 s | 602.231 s |

All four results are wall-clock-shaped and cluster tightly despite alternating
event count. r64's target-accurate result did not reproduce even when returning
to its two-event shape. Therefore:

1. one-token-per-event registration is not a demonstrated fix;
2. event count is not predictive in the current system state;
3. callback debit/Shield code cannot explain the first callback timing because
   the observer-only callback also fired early;
4. r64 remains useful evidence that iOS can sometimes account for the token
   correctly, but not evidence PagePass can select or detect that condition.

Evidence:

- `docs/manual-tests/evidence/2026-07-16-ios18/r67-two-events-repeat-a-1784253659`
- `docs/manual-tests/evidence/2026-07-16-ios18/r68-one-event-repeat-a-valid-1784254443`
- `docs/manual-tests/evidence/2026-07-16-ios18/r69-one-event-repeat-b-1784255105`
- `docs/manual-tests/evidence/2026-07-16-ios18/r70-two-events-repeat-b-1784255775`

### FC Home 5-Minute Control (r71 and r74)

r71 was not a valid FC test. Its input was produced by indexing the encoded
array from a two-token `Set`, whose order is not an app identity contract. The
captured `selection.json` and monitoring readback both contained the canonical
Angry token. FC usage therefore correctly produced no callback in that run.

r74 imported the canonical FC-only selection captured in r59, verified exact
JSON equality after device readback, and registered one explicit application
token with no categories, web domains, or all-activity inclusion. Results were:

| Phase | Measured duration | Result |
| --- | ---: | --- |
| Home/non-target | 308.301 s | Credit 600, unshielded, callback count 0 |
| FC at five minutes | >345 s | Still credit 600, unshielded, callback count 0 |
| FC to callback | 602.084 s | Credit 0, Shield applied, callback count 1 |

SpringBoard recorded FC foreground at `07:02:10.521363`. The monitor event was
persisted at `07:12:12.605465`, and UsageTrackingAgent launched the DeviceActivity
extension in the same second. The result supports selected-app accounting for
FC Mobile and rejects interval wall-clock accounting for this token/run.

Evidence:
`docs/manual-tests/evidence/2026-07-17-ios18/fc-home5-r74-1784296604`.

Keep the child-device lock/unlock and fail-closed enforcement architecture.
Do not treat arbitrary DeviceActivity app-token debit as production-ready yet.
The fresh r45 uninterrupted Angry registration and both FC runs measured the
selected app correctly. r59/r60 show that second-registration failure is not
generic. Angry nevertheless produced early callbacks across normal suspend,
manual force quit, no current-run target session, and non-target controls.
The 900-second value was an experimental quantum, not an Apple 15-minute API
requirement. Reducing it to 60 seconds produced faster but incorrect debits.

The automated XR gate failed even when the selected process remained alive, and
the manual-transition gate failed after a user force quit. A fully manual
no-force-quit run would combine both controls in one run, but neither control is
individually required for the Angry failure. r55 additionally shows that an
Angry foreground session in the current run is not required before its early
callback. r62 additionally rules out PagePass's app container and prior Family
Controls authorization generation. The next destructive discriminator is a
system-level App & Website Activity off/on reset; because it affects the
family's Screen Time reporting and rules, it requires explicit approval and a
user who can reauthorize afterward. The next valid comparison is the production
aggregate event before and after that system reset, repeated with identical
tokens and foreground protocol. The same protocol must also pass with at least
one additional third-party app.

After that, the next gate is the same immutable test on a current physical
iPhone, plus a Feedback Assistant report containing the contrasting Angry and
FC timelines. One-token-per-event registration is not a product direction: it
failed both controlled repeats and does not naturally implement one shared
earned-time balance.

Until that gate passes, the accurate status is:

**Shield control proved. FC Mobile target-only accounting passed three times,
including same-token re-registration and the r74 Home 5-minute control. Angry
Birds failed in all four immutable A-B-B-A
repeats after only 285.576 to 287.071 seconds of foreground use. The historical
r64 success is real but unreproduced; event splitting is neither its established
cause nor a valid shared-credit implementation. Captured state rules out stale
imported PagePass policy, app-container state, and prior authorization
generation as a complete explanation. Automatic debit is not production-safe
until the service-correct aggregate event passes repeated post-system-reset and
third-app gates. This is not evidence that all iOS 18 devices are unsupported or
that PagePass itself uses a simple wall-clock timer.**
