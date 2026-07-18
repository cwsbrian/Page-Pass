# DeviceActivity System-Timed Test Protocol

## Purpose

Prove that PagePass debits earned time from a selected application only. This
protocol does not use screenshots, launch requests, or tester-entered start and
stop timestamps as authoritative timing.

## Required Evidence

1. A physical child iPhone with Family Controls authorization approved.
2. A freshly selected target application token from that child device.
3. One non-target control app, such as Notes.
4. SpringBoard foreground-transition logs from `idevicesyslog`.
5. App Group state and extension event timestamps.
6. `DeviceActivityCenter.events(for:)` readback matching the requested event.

Screen Time behavior on Simulator is not a release signal.

## Event Configuration

- applications: exactly one target token
- categories: empty
- web domains: empty
- `includesAllActivity`: false
- `includesPastActivity`: false
- logical credit: 600 seconds
- measurement grace: 60 seconds
- physical threshold: 660 seconds, represented as 0 h 11 m 0 s
- schedule: absolute, non-repeating, with a unique activity and event name

Abort and fail closed if system readback differs from any requested value.

## Test A: Non-Target Then Target

1. Start the monitor and wait for `intervalDidStart`.
2. Grant 600 seconds and verify the target Shield is removed.
3. Launch Notes and wait for SpringBoard `visibility: Foreground`.
4. Keep Notes foreground for at least 600 system-timed seconds.
5. Verify credit remains 600 and callback count remains zero.
6. Launch the target and wait for its SpringBoard foreground timestamp.
7. Keep it foreground until the extension callback arrives.
8. Compute target use from target foreground to extension callback.

Pass when target use is 600 through 780 seconds. A fixed delivery lag up to two
minutes is acceptable. Fail if target use is below 600 seconds, even when total
schedule elapsed time exceeds 600 seconds.

## Test B: Interrupted Target Use

1. Start and grant as in Test A.
2. Use the target for 300 system-timed seconds.
3. Use Notes for 600 system-timed seconds.
4. Resume the target until callback.
5. Sum only the two target foreground intervals.

Pass when summed target use is 600 through 780 seconds and Notes duration does
not materially change it. This distinguishes a fixed callback delay from
non-target time being incorrectly accumulated.

## Test C: Repetition And Recovery

Run Tests A and B three times with unique monitor names, then repeat once after
a device restart and once after revoke/regrant plus fresh target reselection.
Verify each final callback atomically changes credit to zero and reapplies the
physical Shield while PagePass is backgrounded.

## Required Report Fields

- device model and exact iOS build
- authorization mode and status
- target/control bundle identifiers
- prepared and system-readback event configuration
- interval-start timestamp
- every SpringBoard foreground/background timestamp
- callback and Shield-confirmation timestamps
- target-only foreground sum
- non-target foreground sum
- launch-request-to-system-foreground calibration
- pass/fail reason and evidence directory

Do not convert a short-test discrepancy into a product conclusion unless the
same discrepancy survives this system-timed protocol.
