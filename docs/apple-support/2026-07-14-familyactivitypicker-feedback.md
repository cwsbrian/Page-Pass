# Feedback/DTS Draft: Parent FamilyActivityPicker Omits Authorized Child Apps

## Title

FamilyActivityPicker on an iOS 26 parent device shows no applications from an
authorized iOS 18 child device

## Area

Developer Technologies & SDKs > Family Controls > iOS

## Description

`FamilyActivityPicker` on a parent iPhone does not display applications from an
authorized child iPhone in the same Family Sharing group. The system picker
shows categories, but expanding or searching them produces no application
rows.

Apple's documentation states that a picker on a parent device displays
applications and websites from authorized child devices in the Family Sharing
group:

https://developer.apple.com/documentation/familycontrols/familyactivitypicker

This prevents the documented guardian-device setup flow for a parental control
app. There is no public API that lets the app enumerate or construct equivalent
opaque `ApplicationToken` values.

## Environment

- Parent: iPhone 15, iOS 26.5.2 (23F84)
- Child: iPhone XR, iOS 18.7.9 (22H355)
- Both are physical devices in the same Family Sharing group.
- The child Apple Account has the Child family role.
- Screen Time on the parent can display the child's installed applications.
- Xcode 26.5 SDK
- The same app target, Team ID, and main bundle identifier are installed on
  both devices.
- Family Controls and the same App Group entitlement are present on both
  builds.

## Clean-Room App Identity

```text
Main bundle:       com.pagepass.controlspike.cleanroom20260713
Monitor extension: com.pagepass.controlspike.cleanroom20260713.DeviceActivityMonitor
App Group:         group.com.pagepass.controlspike.cleanroom20260713
```

The clean-room identifiers and provisioning profiles were newly created. The
app was launched on the parent by exact bundle identifier through `devicectl`,
so it could not be confused with a previous installation having the same
display name.

## Steps To Reproduce

1. Install the same clean-room app on the parent and child devices.
2. On the child device, call
   `AuthorizationCenter.shared.requestAuthorization(for: .child)`.
3. Complete guardian approval and verify the child's authorization status is
   `.approved`.
4. On the child device, open `FamilyActivityPicker` and select one individual
   application.
5. Verify the child selection contains one `applicationToken`, zero
   `categoryTokens`, and `includeEntireCategory == false`.
6. On the parent device, do not request `.individual` or `.child`
   authorization.
7. Open `FamilyActivityPicker` from the same clean-room app on the parent.
8. Expand categories and search for applications.

## Expected Result

The parent picker displays applications from the authorized child device, as
documented, and returns opaque application tokens for the guardian's choices.

## Actual Result

No child application rows appear. The picker may show categories, but the
categories contain no applications and search returns no applications.

## Additional Evidence

- Child-device shielding, unshielding, `DeviceActivityMonitor` thresholds,
  automatic debit, and re-shielding all work on the same physical child phone.
- An individual app is visible and selectable in the child picker.
- The same failure occurred with the original app identity and the clean-room
  identity.
- In the original identity test, the Apple-owned `ActivityPickerExtension`
  logged `Detokenized 1/1 applications` for a verified application token while
  the parent picker rendered no application row.
- App selection persistence, category expansion behavior, token encoding, App
  Group state, stale authorization, stale installation, signing, and bundle
  identity mismatch were separately ruled out.
- A parent unified-log archive captured immediately after reproduction shows
  that the Apple picker is hosted by the exact clean-room app identity and that
  FamilyControls performs Shared CloudKit queries and loads token decoding
  keys. The same run then records these Apple-framework messages:

  ```text
  FamilyControlsAgent [com.apple.FamilyControls:syncEngine]
  Skipping activity update because we haven't started collecting activity

  ActivityPickerExtension [com.apple.FamilyControls:xpc]
  Connection error from com.apple.FamilyControlsAgent.private:
  Couldn't communicate with a helper application.

  ActivityPickerExtension [com.apple.FamilyControls:activityPicker]
  Error Domain=NSCocoaErrorDomain Code=4099
  The connection to service named com.apple.FamilyControlsAgent.private was
  invalidated from this process.
  ```

  These errors occur inside Apple-owned processes after the app has presented
  the system picker. No PagePass code participates in catalog loading or
  rendering.
- A current Apple Developer Forums report describes the same categories-only
  parent-picker symptom:
  https://developer.apple.com/forums/tags/family-controls?page=3&sortBy=newest

## Questions For DTS

1. Is an iOS 26 parent with an authorized iOS 18 child a supported
   `FamilyActivityPicker` configuration?
2. Is there any prerequisite beyond the documented child `.child`
   authorization, shared Family Sharing group, same app identity, and Family
   Controls entitlement?
3. Is this a known FamilyControls catalog synchronization or picker rendering
   defect?
4. Is there a supported API-level workaround that preserves guardian-only app
   selection on the guardian device?

## Attachments To Add

- Minimal clean-room Xcode project
- Parent screen recording showing empty categories and search
- Child screen recording showing `.approved` and one selectable application
- Parent and child sysdiagnoses captured immediately after reproduction
- Parent FamilyControls/ActivityPickerExtension console log excerpt
