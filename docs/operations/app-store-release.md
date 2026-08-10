# PagePass App Store Release Checklist

## Code And Archive

- Generate the Xcode project from `apps/mobile-ios/project.yml` before archive.
- Archive the `PagePass` Release scheme with the production team and profiles.
- Confirm the app identifier is `com.pagepass.app` and the monitor identifier is
  `com.pagepass.app.DeviceActivityMonitor`.
- Confirm both signed targets contain the Family Controls distribution
  entitlement and the shared `group.com.pagepass.app` App Group entitlement.
- Confirm the app contains the production APNs entitlement and the extension
  does not request an APNs entitlement.
- Inspect the archive and confirm both the app and monitor bundles contain their
  own `PrivacyInfo.xcprivacy` file.
- Confirm Release uses the production HTTPS API, contains no local parent token,
  and does not allow arbitrary network loads.
- Run `pnpm ios:release-verify` for unsigned Release bundle/configuration checks.
- Run `pnpm ios:archive-verify -- /path/to/PagePass.xcarchive` on the actual
  signed archive. This is the authoritative entitlement/provisioning gate.
- Run the complete API suite and `pnpm exec nx run mobile-ios:test` from the same
  revision being submitted.

## App Store Connect

- Obtain Apple's Family Controls distribution approval for both identifiers and
  regenerate distribution profiles after approval.
- Enter the production `/privacy` URL after legal review and confirm `/terms` is
  publicly reachable over HTTPS.
- Make App Privacy answers match `App/PrivacyInfo.xcprivacy`: linked name, email,
  user/device identifiers, reading-report images and text, and product
  interaction; no tracking.
- Complete age-rating and children/family privacy review with legal counsel.
- Review the English String Catalog and add only product-approved languages to
  App Store Connect; do not claim an unreviewed translation.
- Provide a review account and instructions that explain the Parent and Child
  installation roles, pairing, Screen Time authorization, reading submission,
  approval, and Earned Time behavior.
- Explain that the monitor extension applies restrictions locally on the child
  device and that an active Apple Family/Screen Time setup is needed for the
  complete review flow.

## TestFlight Gates

- Verify parent and child authentication against the production API.
- Verify sandbox-to-production APNs registration and delivery from TestFlight.
- Verify notification tap routing from foreground, background, and terminated
  parent/child app states.
- Verify a reinstall rotates push and child credentials and that APNs
  `Unregistered` removes stale tokens.
- Verify a child-device reboot restores an active-session policy and a revoked
  Screen Time authorization fails closed.
- Submit a representative handwritten report and verify private upload, OCR,
  parent review, credit creation, and media reads end to end.

Do not submit until the public legal text, privacy manifest, App Store privacy
answers, and actual production data handling agree.
