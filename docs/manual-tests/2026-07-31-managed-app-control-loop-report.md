# Managed App Control Loop Physical-Device Report

Date: 2026-07-31

## Environment

- Parent: iPhone 15, iOS 26.5.2
- Child: iPhone XR, iOS 18.7.9
- App bundle: `com.pagepass.app` on both devices
- API: local Fastify server at `http://192.168.30.164:8787`
- Database: PostgreSQL in Docker

## Passed

- Parent created a child profile and generated a six-digit pairing code.
- Child consumed the code and received a device credential and snapshot.
- Child Screen Time authorization reported `Approved`.
- Child selected two application tokens and registered them with the server.
- Initial policy version applied as `blocked` and the child acknowledged it.
- Default-deny category shielding blocked selected and unregistered apps.
- Child requested one app; parent received and approved it as `earned_time`.
- Child synced the new policy and preserved the other app as `blocked`.
- Parent granted credit and child started and activated an Earned Time session.
- During the session, the Earned Time app unlocked while the blocked app stayed locked.
- Returning to PagePass did not stop the active session.
- Manual Stop immediately reapplied the locked policy and settled server credit.
- Session 1 consumed 62 of 900 seconds and left 838 seconds.
- Session 2 consumed 221 of 1,738 seconds and left 1,517 seconds.
- PagePass was force-terminated and relaunched during session 3. The same
  active session and timer recovered without creating or settling another
  session. The UI showed only Stop while active. Final settlement consumed 569
  of 1,517 seconds and left 948 seconds.
- Safari was hidden and web access blocked outside a session, restored during a
  session, and hidden again after Stop.
- Automatic expiry attempt 2 passed the background callback and local state
  transition with the host app terminated. A 900-second session started at
  `2026-07-31 23:48:56.494Z` and was scheduled to end at
  `2026-08-01 00:03:56.494Z`. The monitor extension received
  `intervalDidEnd` about 2.48 seconds after its registered schedule end, applied
  the no-session policy, moved the local session to `settlement_pending`, queued
  one idempotent settlement for 900 seconds, and reduced the local balance to
  zero without foreground reconciliation.
- Relaunching PagePass uploaded the pending settlement. The server recorded the
  session as `settled`, `end_reason=expired`, `consumed_seconds=900`, and
  `balance_after_seconds=0`.
- A separate 120-second DEBUG verification used a valid 15-minute monitoring
  interval with an end warning 13 minutes before the system interval end. With
  the PagePass host terminated, the warning callback arrived about 1.62 seconds
  after the logical two-minute deadline, queued one 120-second settlement, and
  reduced the local balance from 239 to 119 seconds.
- Before PagePass was foregrounded, the tester confirmed from the Home Screen
  that Safari was hidden and Angry Birds showed its Shield. This physically
  verifies background relocking independently of foreground reconciliation.
- Foregrounding PagePass then uploaded the pending settlement. The server
  recorded `state=settled`, `end_reason=expired`, `consumed_seconds=120`, and
  `balance_after_seconds=119`.
- The patched offline Stop flow passed on the iPhone XR. A max-duration session
  started at `2026-08-04 23:33:54.257Z` with 1,459 seconds available. The child
  went offline and stopped at `23:35:23.300Z`; the local state immediately
  locked both Angry Birds (`earned_time`) and Notes (`blocked`), queued exactly
  one settlement for 90 seconds, and showed a 1,369-second balance. The server
  correctly remained active with a 1,459-second balance while the device was
  offline.
- The child uploaded that settlement at `23:37:44.449Z`, about 141 seconds
  after the persisted Stop time. The API charged exactly 90 seconds rather than
  the network delay, stored one ledger spend of `-90`, and returned a canonical
  balance of 1,369 seconds. The child then cleared its pending queue and matched
  the server balance.
- Parent app-request notification delivery passed on the two physical devices.
  The parent iPhone registered one sandbox APNs token through
  `PUT /v1/parent/push-devices`; the server stored only its encrypted envelope
  and digest. The child created a new request at `2026-08-05 00:14:09.235Z`,
  the transactional outbox event was created 7 ms later, and APNs accepted it
  on the first attempt at `00:14:09.828Z` (586 ms from outbox creation). The
  parent received the alert and the request appeared without polling or manual
  refresh. No failed or pending delivery remained.

## Defects Found And Patched

- App Group policy data was written successfully, but
  `UserDefaults.synchronize()` returned `false`. The app treated that advisory
  return value as a storage failure and skipped managed-app registration.
  Policy and session stores now verify immediate read-back instead.
- Equal-version policy sync previously skipped enforcement. It now reapplies
  the active or inactive Shield policy, allowing reboot/reinstall recovery and
  new enforcement rules to take effect without ending an active session.
- Automatic expiry attempt 1 left the session active after its deadline. The
  next build now clears stale earned-time monitors before registering a new
  schedule and records registration, start, end-received, end-settled, and
  end-failed diagnostics in the App Group for physical-device verification.
- The first offline Stop attempt persisted the correct local result before any
  network request: 58 seconds consumed, 961 seconds remaining, and exactly one
  pending idempotent settlement. However, stopping the DeviceActivity schedule
  synchronously delivered `intervalDidEnd` before the host had persisted its
  ending phase. The extension treated that early callback as an expiry failure
  and its emergency policy replaced explicit application tokens with category
  shielding. Angry Birds stayed locked, but Notes became available. The host
  now persists the ending phase before cancelling the schedule, early end
  callbacks are ignored until the logical deadline, and emergency fallback
  preserves all known blocked and Earned Time tokens.
- When the first offline Stop settlement was uploaded several minutes later,
  the API ignored the device's persisted Stop time and billed through the
  server receive time: 460 seconds instead of 58. Manual Stop settlement now
  uses the reported end time after checking it against the server-started
  session, server time, and expiry. The PostgreSQL integration test covers a
  delayed offline upload and rejects end times more than 30 seconds ahead of
  server time.
- Re-pairing the same active installation previously rotated its credential and
  reset the device to `pending_setup`, making child requests return 401. It now
  preserves the active setup and managed apps while rotating the credential;
  the old credential is rejected and the new credential works immediately.
- The first push integration test exposed mixed time sources: outbox
  `next_attempt_at` used the database clock while the service used its injected
  clock, so an immediate event could be skipped. Event creation now writes the
  retry timestamp from the same service clock as the request transaction.
- APNs permanent provider errors such as `InvalidProviderToken` previously
  could be mislabeled as sent. The worker now records an unsent `failed` event
  with the APNs reason, while transient `429/5xx` responses remain retryable and
  invalid device tokens are revoked.

## Deferred Product Decisions

- Parent-configurable control for iOS system/default apps that are not covered
  reliably by category-wide shielding. Safari is temporarily treated as an
  Earned Time system app.
- Additional physical-device coverage for the new five-minute preset across
  supported iOS versions. The family setting and control-loop path are implemented.

## Remaining Physical Tests

- Verify production APNs delivery from a Release/TestFlight build.
- Verify token rotation and APNs `Unregistered` cleanup on a reinstalled parent
  device. The server-side rotation and invalid-token paths are automated.
- Verify alert tap recovery when the parent app starts from a terminated state.
- Verify active-session policy recovery after a child-device reboot and the
  fail-closed state after Screen Time authorization is revoked.

## Failed Attempt Kept For Comparison

- Automatic expiry attempt 1 used a 948-second session. It remained locally
  active more than four minutes after its deadline, and Safari plus the Earned
  Time app remained available. Foreground reconciliation immediately relocked
  and settled it with `end_reason=recovery`.
