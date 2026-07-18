# Screen Time Spike

This directory preserves the experimental iOS project and device harnesses used
to reduce uncertainty around Apple's Screen Time frameworks. It is validation
evidence, not part of the PagePass product build.

## What "spike" means

In software development, a spike is a deliberately narrow, time-bounded
experiment. Its purpose is to answer a risky technical question with working
evidence. A spike may use debug-only UI, hard-coded test assumptions, and rough
implementation choices because learning is the deliverable; production-quality
code is not.

This spike was used to validate:

- Family Controls authorization and application selection on physical devices.
- Managed Settings shield application and removal.
- Device Activity callbacks and background re-lock behavior.
- Wall-clock Earned Time sessions, manual stop, and elapsed-time settlement.
- Observed iOS 18 behavior and physical-device test harnesses.

The product implementation lives in `../../apps/mobile-ios`. Product code must
not import, build, or depend on this directory.

## Running the archived project

Commands from the historical spike plans are relative to this directory:

```sh
cd spikes/screen-time
xcodebuild -list -project PagePassControlSpike.xcodeproj
```

Scripts that capture physical-device evidence are under `scripts/`.

## Deletion gate

Delete this entire directory after all of the following are true:

1. The product app reproduces authorization, policy sync, lock/unlock, manual
   stop, background expiry, force-quit recovery, and reboot recovery on the
   supported physical-device matrix.
2. Required outcomes and known OS limitations are preserved in
   `../../docs/manual-tests`.
3. Product code, build configuration, CI, and current documentation have no
   dependency on this directory.
4. The team no longer needs the archived app for comparison or regression
   investigation.

Deleting the source does not uninstall the spike app or revoke its Family
Controls authorization on test devices; perform device cleanup separately.
