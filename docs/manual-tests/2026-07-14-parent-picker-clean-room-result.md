# Parent FamilyActivityPicker Clean-Room Result

## Decision

Remote per-app selection on the parent's iPhone is a documented Apple
FamilyControls capability, but the Apple-owned picker path fails in the tested
family/device environment.

Apple's current `FamilyActivityPicker` documentation explicitly says that a
picker shown on a parent device displays applications and websites from
authorized child devices in the Family Sharing group:

https://developer.apple.com/documentation/familycontrols/familyactivitypicker

Apple's WWDC21 Screen Time API session also shows the same app installed on the
guardian and child devices, authorization on the child device, and later rules
and app selection on the guardian device:

https://developer.apple.com/videos/play/wwdc2021/10123/

This is not a PagePass selection persistence, token transfer, App Group,
provisioning, or stale-install failure. Do not add an app-side workaround that
enumerates or manufactures `ApplicationToken` values; Apple exposes no
supported API for that.

## Devices

| Role | Device | OS | Family role |
| --- | --- | --- | --- |
| Parent | iPhone 15 | iOS 26.5.2 (23F84) | Organizer/parent |
| Child | iPhone XR | iOS 18.7.9 (22H355) | Child |

## Proven Before Clean Room

- Child `.child` authorization completed with parent approval.
- Local child-device shield, unshield, `DeviceActivityMonitor` callback, usage
  debit, and automatic re-shield were proven on physical hardware.
- A true individual app selection encoded as one application token, zero
  category tokens, and `includeEntireCategory == false`.
- The same encoded application token reached the parent unchanged.
- Apple-owned `ActivityPickerExtension` logged that it detokenized one of one
  application tokens, while the picker still rendered no app row.

## Clean-Room Reproduction

The test replaced all identity-scoped state:

```text
App bundle:       com.pagepass.controlspike.cleanroom20260713
App Group:        group.com.pagepass.controlspike.cleanroom20260713
Authorization:    newly granted .child authorization
Provisioning:     newly generated profiles
Selection:        one individual app, zero categories
```

Procedure:

1. Install the same clean-room build on the child and parent iPhones.
2. Revoke the original app's child authorization.
3. Request and approve fresh `.child` authorization for the clean-room app on
   the child iPhone.
4. Select one individual app on the child iPhone.
5. Verify the child App Group contains one application token and zero category
   tokens.
6. Open `FamilyActivityPicker` in the clean-room app on the parent iPhone.

Observed result:

```text
Child selection:  1 application, 0 categories
Parent picker:    no child application rows
```

The parent unified log captured the Apple-owned picker failing its private
helper connection with Cocoa error 4099. `FamilyControlsAgent` also logged that
it skipped the activity update because activity collection had not started,
despite completing Shared CloudKit queries and loading token decoding keys.

## Ruled-Out Causes

- PagePass picker binding and selection persistence
- Category selection accidentally replacing an individual app selection
- Corrupt or mismatched encoded selection payload
- Original bundle/App Group CloudKit state
- Stale install or stale authorization tied to the original app identity
- Mismatched app/extension identifiers or entitlements

## Unsupported Workarounds

`FamilyActivityData.installedApplications`, added in iOS 26.4, is not a
replacement for the parent picker. It accesses a person's current-device,
non-tokenized app data, requires the separate Family Controls App and Website
Usage entitlement and `approvedWithDataAccess`, and customer use is restricted
to devices and Apple Accounts in the EU. PagePass must support Canadian and
other non-EU families.

https://developer.apple.com/documentation/familycontrols/familyactivitydata

The parent cannot use `.individual` authorization as a workaround because that
authorizes the parent's own device. The public authorization API has only
`.child` and `.individual`; there is no parent-side authorization member.

## Product Impact

Parent-only per-app setup remains a product requirement. Child-device setup is
not an equivalent MVP fallback because it requires access to the child phone.

Continue work that does not depend on the remote picker: child enforcement,
ledger synchronization, multiple-child policy modeling, parent approvals, and
OCR. Keep remote parent per-app selection behind a capability flag until Apple
resolves or explains the picker behavior.

Next isolation test: run the same build with the parent and child on the same
major iOS release. The current pair is iOS 26.5.2 on the parent and iOS 18.7.9
on the child. The API is available on both, but this test will distinguish an
iOS 26-to-18 interoperability regression from family-account state.

Next platform action: file Feedback Assistant and a DTS Technical Support
Incident as a documented API contract violation. Attach this matrix, the
parent picker screen recording, FamilyControls logs, and a sysdiagnose from
both devices when practical.
