# Screen Time Control Loop Physical Test Checklist

## Device Setup

- [ ] Physical iPhone model:
- [ ] iOS version:
- [ ] Build number:
- [ ] App signing profile includes Family Controls and App Group.
- [ ] Monitor signing profile includes Family Controls and App Group.
- [ ] Device is signed into child Apple ID in Family Sharing.
- [ ] Guardian approval for `.child` authorization is available.
- [ ] Tap "Request Child Authorization" in PagePass.
- [ ] Record authorization result text from PagePass:
- [ ] Authorization result says child authorization was granted.
- [ ] Downtime disabled.
- [ ] App Limits disabled for selected app.
- [ ] Always Allowed does not include selected app.

## Gate 0 Required Proof

- [ ] Child/teen Apple ID is signed into the child iPhone and is in Family Sharing.
- [ ] Parent/guardian approval device is available.
- [ ] Tap "Request Child Authorization" in PagePass.
- [ ] Record Request Child Authorization result:
- [ ] Confirm Request Child Authorization succeeded with `.child`.
- [ ] Background fallback proof: cleanup, select one token, Start Fallback Proof Run, wait for `intervalDidStart`, Add Proof Credit After intervalDidStart, background PagePass, use selected app until threshold.
- [ ] Background fallback proof: capture screenshot/video of re-shield before reopening PagePass.
- [ ] Background fallback proof: reopen PagePass and confirm event log has source `extension`.
- [ ] Background fallback proof: confirm event log has matching run id, activity name, event name, credit before/after, token count, and final credit 0.
- [ ] Force-quit fallback proof: cleanup, select one token, Start Fallback Proof Run, wait for `intervalDidStart`, Add Proof Credit After intervalDidStart, force quit PagePass, use selected app until threshold.
- [ ] Force-quit fallback proof: capture screenshot/video of re-shield before reopening PagePass.
- [ ] Force-quit fallback proof: reopen PagePass and confirm event log has source `extension`.
- [ ] Force-quit fallback proof: confirm event log has matching run id, activity name, event name, credit before/after, token count, and final credit 0.

## Gate 0b Conditional Quantized Debit Proof

- [ ] Background quantized proof: cleanup, select one token, Start Quantized Proof Run, wait for `intervalDidStart`, Add Proof Credit After intervalDidStart, confirm credit starts at 120s, background PagePass.
- [ ] Background quantized proof: use selected app through first and second thresholds without reopening PagePass between them.
- [ ] Background quantized proof: after second threshold/re-shield, reopen PagePass.
- [ ] Background quantized proof: confirm first threshold event, `next quantized threshold armed`, second threshold event, first threshold credit after 60s, and final credit 0.
- [ ] Force-quit quantized proof: cleanup, select one token, Start Quantized Proof Run, wait for `intervalDidStart`, Add Proof Credit After intervalDidStart, confirm credit starts at 120s, force quit PagePass.
- [ ] Force-quit quantized proof: use selected app through first and second thresholds without reopening PagePass between them.
- [ ] Force-quit quantized proof: after second threshold/re-shield, reopen PagePass.
- [ ] Force-quit quantized proof: confirm first threshold event, `next quantized threshold armed`, second threshold event, first threshold credit after 60s, and final credit 0.
- [ ] If either quantized proof fails, mark quantized rejected and use single-threshold fallback.

## Gate 1 Limited App Selection Architecture

- [ ] Parent iPhone is in the same Family Sharing group.
- [ ] Open FamilyActivityPicker on parent iPhone.
- [ ] Record whether child apps appear:
- [ ] Record whether tokens persist:
- [ ] Tap "Export Selection Payload" on parent iPhone.
- [ ] Send base64 payload to child iPhone by AirDrop, Messages, or Notes.
- [ ] Paste base64 payload into the PagePass selection payload text box on the child iPhone.
- [ ] Tap "Import Selection Payload" on child iPhone.
- [ ] Confirm child device can apply shield from transferred selection.
- [ ] Confirm child device can monitor DeviceActivity from transferred selection.
- [ ] Decision: remote picker accepted, or remote rejected.
- [ ] If remote rejected, fallback requires follow-up Parent Setup Mode proof before backend/policy work.

## Negative Control Same Run Shape

- [ ] Cleanup reset run.
- [ ] Select exactly one application token.
- [ ] Record selected app name:
- [ ] Record non-selected app name:
- [ ] Start Fallback Proof Run.
- [ ] Wait for `intervalDidStart`.
- [ ] Add Proof Credit After intervalDidStart and unlock.
- [ ] Use non-selected app longer than threshold.
- [ ] Confirm credit unchanged.
- [ ] Record unchanged credit value:
- [ ] Tap "Record Negative-Control Passed" in PagePass.
- [ ] Confirm event log includes `negative control passed`.
- [ ] If credit changed or threshold fired, tap "Record Negative-Control Failed" and stop the spike.
- [ ] Use selected app in same run.
- [ ] Confirm threshold fires and credit reaches zero; capture screenshot/video of re-shield.
- [ ] Confirm threshold event log has matching run id, activity name, event name, credit before/after, and token count.
