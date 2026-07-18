#!/bin/zsh

set -eu
set -o pipefail
export PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"

if (( $# != 9 && $# != 12 )); then
    print -u2 "usage: $0 DEVICE UDID GROUP BUNDLE LEASE TAKEOVER_LEASE TAKEOVER_NONCE NONCE SESSION_DIR [CREDIT_SECONDS QUANTUM_SECONDS NOTES_SECONDS]"
    exit 64
fi

DEVICE=$1
UDID=$2
GROUP=$3
BUNDLE=$4
LEASE=$5
TAKEOVER_LEASE=$6
TAKEOVER_NONCE=$7
NONCE=$8
SESSION=$9
CREDIT_SECONDS=${10:-1800}
QUANTUM_SECONDS=${11:-900}
NOTES_DURATION_SECONDS=${12:-1050}
MEASUREMENT_GRACE_SECONDS=60
PHYSICAL_THRESHOLD_SECONDS=$((QUANTUM_SECONDS + MEASUREMENT_GRACE_SECONDS))
CALLBACK_TIMEOUT_SECONDS=$((PHYSICAL_THRESHOLD_SECONDS + 160))
(( CREDIT_SECONDS == QUANTUM_SECONDS * 2 )) \
    || { print -u2 "validation requires exactly two equal quanta"; exit 64; }
CSV="$SESSION/samples.csv"
CURRENT="$SESSION/current.plist"
STARTED_AT=$(date +%s)

mkdir "$SESSION"
printf 'phase,sample,epoch,elapsed,credit,shielded,hits,run,lease\n' > "$CSV"
jq -n \
    --arg device "$DEVICE" --arg udid "$UDID" --arg group "$GROUP" \
    --arg bundle "$BUNDLE" --arg lease "$LEASE" --arg takeover "$TAKEOVER_LEASE" \
    --arg takeoverNonce "$TAKEOVER_NONCE" \
    --arg nonce "$NONCE" --argjson startedAt "$STARTED_AT" \
    --argjson credit "$CREDIT_SECONDS" --argjson quantum "$QUANTUM_SECONDS" \
    --argjson notesDuration "$NOTES_DURATION_SECONDS" \
    --argjson grace "$MEASUREMENT_GRACE_SECONDS" \
    '{device:$device,udid:$udid,group:$group,bundle:$bundle,lease:$lease,takeoverLease:$takeover,takeoverNonce:$takeoverNonce,nonce:$nonce,startedAt:$startedAt,creditSeconds:$credit,quantumSeconds:$quantum,notesDurationSeconds:$notesDuration,measurementGraceSeconds:$grace}' \
    > "$SESSION/manifest.json"

fail() {
    print -r -- "$1" > "$SESSION/FAIL"
    exit "${2:-1}"
}

copy_state() {
    rm -f "$CURRENT"
    xcrun devicectl device copy from \
        --device "$DEVICE" \
        --domain-type appGroupDataContainer \
        --domain-identifier "$GROUP" \
        --source "Library/Preferences/$GROUP.plist" \
        --destination "$CURRENT" >/dev/null
}

state_json() {
    plutil -extract state raw -o - "$CURRENT" | base64 -D
}

events_json() {
    plutil -extract events raw -o - "$CURRENT" | base64 -D
}

owner_field() {
    plutil -extract automationOwnership raw -o - "$CURRENT" | base64 -D | jq -er ".$1"
}

require_ownership() {
    local actual_lease=$(owner_field lease)
    local actual_nonce=$(owner_field lastNonce)
    [[ "$actual_lease" == "$LEASE" ]] || fail "lease changed from $LEASE to $actual_lease" 10
    [[ "$actual_nonce" == "$NONCE" ]] || fail "generation changed from $NONCE to $actual_nonce" 25
}

append_sample() {
    local phase=$1 sample=$2 started=$3
    local now elapsed json credit shielded hits run actual_lease
    now=$(date +%s)
    elapsed=$((now - started))
    json=$(state_json)
    credit=$(print -rn -- "$json" | jq -er '.creditSeconds')
    shielded=$(print -rn -- "$json" | jq -r '.isShielded')
    hits=$(print -rn -- "$json" | jq -er '.thresholdReachedCount')
    run=$(print -rn -- "$json" | jq -r '.activeRunID // "-"')
    actual_lease=$(owner_field lease)
    print "$phase,$sample,$now,$elapsed,$credit,$shielded,$hits,$run,$actual_lease" >> "$CSV"
}

recover_pending_marker_or_fail() {
    local phase=$1
    if print -rn -- "$json" | jq -e '.thresholdDebitPending == true' >/dev/null; then
        xcrun devicectl device process launch --device "$DEVICE" --terminate-existing \
            --json-output "$SESSION/pending-marker-recovery-$phase.json" "$BUNDLE" >/dev/null
        sleep 5
        copy_state
        require_ownership
        fail "persisted threshold marker required host-app recovery during $phase" 27
    fi
}

xcrun devicectl device info processes --device "$DEVICE" \
    --json-output "$SESSION/processes-before-baseline.json" >/dev/null
BASELINE_ANGRY_PID=$(jq -er '.. | objects | select((.executable? // "") | contains("AngryBirds2.app")) | .processIdentifier' "$SESSION/processes-before-baseline.json" | head -1 || true)
if [[ -n "$BASELINE_ANGRY_PID" ]]; then
    xcrun devicectl device process terminate --device "$DEVICE" --pid "$BASELINE_ANGRY_PID" --kill >/dev/null
fi
xcrun devicectl device process launch --device "$DEVICE" --terminate-existing \
    --json-output "$SESSION/baseline-notes-launch.json" com.apple.mobilenotes >/dev/null
sleep 1

xcrun devicectl device process launch \
    --device "$DEVICE" --terminate-existing \
    --json-output "$SESSION/pagepass-launch.json" "$BUNDLE" \
    --pagepass-auto-managed-proof --pagepass-auto-replace-run \
    --pagepass-credit-seconds="$CREDIT_SECONDS" --pagepass-quantum-seconds="$QUANTUM_SECONDS" \
    --pagepass-automation-lease="$LEASE" \
    --pagepass-automation-nonce="$NONCE" \
    --pagepass-automation-takeover-from="$TAKEOVER_LEASE" \
    --pagepass-automation-takeover-nonce="$TAKEOVER_NONCE" >/dev/null

ownership_ready=false
for _ in {1..20}; do
    sleep 1
    copy_state
    actual_lease=$(owner_field lease 2>/dev/null || true)
    actual_nonce=$(owner_field lastNonce 2>/dev/null || true)
    if [[ "$actual_lease" == "$LEASE" && "$actual_nonce" == "$NONCE" ]]; then
        ownership_ready=true
        break
    fi
done
[[ "$ownership_ready" == true ]] || fail "new automation ownership did not become visible" 29

INITIAL_RUN=""
for _ in {1..30}; do
    sleep 2
    copy_state
    require_ownership
    json=$(state_json)
    if [[ $(print -rn -- "$json" | jq -r '[.creditSeconds,.isShielded,.thresholdReachedCount,.intervalDidStart,.monitoringCompromised] | @tsv') == "$CREDIT_SECONDS"$'\tfalse\t0\ttrue\tfalse' ]]; then
        candidate_run=$(print -rn -- "$json" | jq -er '.activeRunID')
        events=$(events_json)
        if print -rn -- "$events" | jq -e \
            --arg run "$candidate_run" --arg nonce "$NONCE" --argjson started "$STARTED_AT" '
                any(.[];
                    .name == "automation ready" and .runID == $run and
                    (.detail | contains("generation=" + $nonce)) and
                    (.timestamp + 978307200) >= $started
                )
            ' >/dev/null; then
            INITIAL_RUN=$candidate_run
            break
        fi
    fi
done
[[ -n "$INITIAL_RUN" ]] || fail "initial managed run did not become ready" 11
cp "$CURRENT" "$SESSION/initial-ready.plist"
jq --arg run "$INITIAL_RUN" '.initialRun=$run' "$SESSION/manifest.json" > "$SESSION/manifest.next"
mv "$SESSION/manifest.next" "$SESSION/manifest.json"

ANGRY1_START=$(date +%s)
xcrun devicectl device process launch --device "$DEVICE" --terminate-existing \
    --json-output "$SESSION/angry1-launch.json" com.rovio.baba >/dev/null
sample=0
SUCCESSOR_RUN=""
while true; do
    elapsed=$(($(date +%s) - ANGRY1_START))
    if (( elapsed < QUANTUM_SECONDS )); then
        sleep 15
    else
        sleep 0.1
    fi
    copy_state
    require_ownership
    append_sample angry1 "$sample" "$ANGRY1_START"
    json=$(state_json)
    recover_pending_marker_or_fail angry1
    run=$(print -rn -- "$json" | jq -r '.activeRunID // "-"')
    elapsed=$(($(date +%s) - ANGRY1_START))
    if [[ "$run" != "$INITIAL_RUN" ]]; then
        (( elapsed >= QUANTUM_SECONDS )) || fail "first callback was before the logical ${QUANTUM_SECONDS}s floor at ${elapsed}s" 12
        SUCCESSOR_RUN=$run
        SUCCESSOR_SCHEDULE_START=$(print -rn -- "$json" | jq -er '.monitoringIntervalStart + 978307200')
        NOTES_LAUNCH_REQUEST_AT=$(perl -MTime::HiRes=time -e 'printf "%.6f", time')
        xcrun devicectl device process launch --device "$DEVICE" --terminate-existing \
            --json-output "$SESSION/notes-launch.json" com.apple.mobilenotes >/dev/null
        NOTES_FOREGROUND_CONFIRMED_AT=$(perl -MTime::HiRes=time -e 'printf "%.6f", time')
        NOTES_START=$(date +%s)
        break
    fi
    (( elapsed < CALLBACK_TIMEOUT_SECONDS )) || fail "first callback did not arrive by ${elapsed}s" 13
    sample=$((sample + 1))
done
[[ "$SUCCESSOR_RUN" != "-" ]] || fail "first callback ended instead of rearming" 14
cp "$CURRENT" "$SESSION/first-threshold.plist"

ready=false
for _ in {1..20}; do
    sleep 2
    copy_state
    require_ownership
    json=$(state_json)
    values=$(print -rn -- "$json" | jq -r '[.activeRunID,.creditSeconds,.isShielded,.thresholdReachedCount,.intervalDidStart,.quantumRearmPending,.monitoringCompromised] | @tsv')
    if [[ "$values" == "$SUCCESSOR_RUN"$'\t'"$QUANTUM_SECONDS"$'\tfalse\t1\ttrue\tfalse\tfalse' ]]; then
        ready=true
        break
    fi
done
[[ "$ready" == true ]] || fail "successor one-shot did not become ready" 15
cp "$CURRENT" "$SESSION/successor-ready.plist"
events=$(events_json)
SUCCESSOR_INTERVAL_STARTED_AT=$(print -rn -- "$events" | jq -er --arg run "$SUCCESSOR_RUN" '
    [.[] | select(.name == "interval did start" and .runID == $run) | (.timestamp + 978307200)] | last
')
SUCCESSOR_CARRYOVER_UPPER_SECONDS=$(perl -e '
    my ($confirmed, $started) = @ARGV;
    my $carryover = $confirmed - $started;
    $carryover = 0 if $carryover < 0;
    printf "%.6f", $carryover;
' "$NOTES_FOREGROUND_CONFIRMED_AT" "$SUCCESSOR_INTERVAL_STARTED_AT")
SECOND_CALLBACK_EARLIEST=$(perl -MPOSIX=ceil -e '
    my ($physical, $logical, $carryover) = @ARGV;
    my $earliest = $physical - ceil($carryover) - 2;
    $earliest = $logical if $earliest < $logical;
    print $earliest;
' "$PHYSICAL_THRESHOLD_SECONDS" "$QUANTUM_SECONDS" "$SUCCESSOR_CARRYOVER_UPPER_SECONDS")
jq --argjson successorScheduleStart "$SUCCESSOR_SCHEDULE_START" \
    --argjson successorIntervalStartedAt "$SUCCESSOR_INTERVAL_STARTED_AT" \
    --argjson notesLaunchRequestAt "$NOTES_LAUNCH_REQUEST_AT" \
    --argjson notesForegroundConfirmedAt "$NOTES_FOREGROUND_CONFIRMED_AT" \
    --argjson carryoverUpperSeconds "$SUCCESSOR_CARRYOVER_UPPER_SECONDS" \
    --argjson secondCallbackEarliest "$SECOND_CALLBACK_EARLIEST" '
        .successorScheduleStart=$successorScheduleStart |
        .successorIntervalStartedAt=$successorIntervalStartedAt |
        .notesLaunchRequestAt=$notesLaunchRequestAt |
        .notesForegroundConfirmedAt=$notesForegroundConfirmedAt |
        .successorCarryoverUpperSeconds=$carryoverUpperSeconds |
        .secondCallbackEarliest=$secondCallbackEarliest
    ' \
    "$SESSION/manifest.json" > "$SESSION/manifest.next"
mv "$SESSION/manifest.next" "$SESSION/manifest.json"
print -rn -- "$events" | jq -e --arg old "$INITIAL_RUN" --arg new "$SUCCESSOR_RUN" '
    any(.[]; .name == "threshold reached" and .runID == $old) and
    any(.[]; .name == "next quantum armed" and .runID == $new) and
    any(.[]; .name == "interval did start" and .runID == $new)
' >/dev/null || fail "successor event lineage is incomplete" 16
print -rn -- "$events" | jq -e --arg run "$INITIAL_RUN" --argjson launch "$ANGRY1_START" --argjson logical "$QUANTUM_SECONDS" '
    any(.[];
        .name == "threshold reached" and .runID == $run and
        ((.timestamp + 978307200) - $launch) >= $logical
    )
' >/dev/null || fail "first callback event timestamp was before the logical usage floor" 23

xcrun devicectl device info processes --device "$DEVICE" \
    --json-output "$SESSION/processes-before-notes.json" >/dev/null
ANGRY_PID=$(jq -er '.. | objects | select((.executable? // "") | contains("AngryBirds2.app")) | .processIdentifier' "$SESSION/processes-before-notes.json" | head -1 || true)
if [[ -n "$ANGRY_PID" ]]; then
    xcrun devicectl device process terminate --device "$DEVICE" --pid "$ANGRY_PID" --kill >/dev/null
fi
sample=0
while (( $(date +%s) - NOTES_START < NOTES_DURATION_SECONDS )); do
    sleep 15
    copy_state
    require_ownership
    append_sample notes "$sample" "$NOTES_START"
    json=$(state_json)
    values=$(print -rn -- "$json" | jq -r '[.activeRunID,.creditSeconds,.isShielded,.thresholdReachedCount,.monitoringCompromised] | @tsv')
    [[ "$values" == "$SUCCESSOR_RUN"$'\t'"$QUANTUM_SECONDS"$'\tfalse\t1\tfalse' ]] \
        || fail "Notes negative control changed the successor run" 17
    sample=$((sample + 1))
done
cp "$CURRENT" "$SESSION/notes-complete.plist"

ANGRY2_START=$(date +%s)
xcrun devicectl device process launch --device "$DEVICE" --terminate-existing \
    --json-output "$SESSION/angry2-launch.json" com.rovio.baba >/dev/null
sample=0
while true; do
    sleep 15
    copy_state
    require_ownership
    append_sample angry2 "$sample" "$ANGRY2_START"
    json=$(state_json)
    recover_pending_marker_or_fail angry2
    credit=$(print -rn -- "$json" | jq -er '.creditSeconds')
    shielded=$(print -rn -- "$json" | jq -r '.isShielded')
    hits=$(print -rn -- "$json" | jq -er '.thresholdReachedCount')
    run=$(print -rn -- "$json" | jq -r '.activeRunID // "-"')
    elapsed=$(($(date +%s) - ANGRY2_START))
    if [[ "$credit" == 0 && "$shielded" == true && "$hits" == 2 && "$run" == "-" ]]; then
        (( elapsed >= SECOND_CALLBACK_EARLIEST )) \
            || fail "second callback was early at ${elapsed}s (carryover upper bound ${SUCCESSOR_CARRYOVER_UPPER_SECONDS}s)" 18
        break
    fi
    [[ "$run" == "$SUCCESSOR_RUN" ]] || fail "successor ownership changed before final debit" 19
    (( elapsed < CALLBACK_TIMEOUT_SECONDS )) || fail "second callback did not arrive by ${elapsed}s" 20
    sample=$((sample + 1))
done
cp "$CURRENT" "$SESSION/final-state.plist"
events=$(events_json)
print -rn -- "$events" | jq -e --arg run "$SUCCESSOR_RUN" '
    any(.[]; .name == "threshold reached" and .runID == $run and .creditAfter == 0) and
    any(.[]; .name == "fail-closed shield confirmed" and .runID == $run)
' >/dev/null || fail "final event lineage is incomplete" 21
print -rn -- "$events" | jq -e --arg run "$SUCCESSOR_RUN" --argjson launch "$ANGRY2_START" --argjson earliest "$SECOND_CALLBACK_EARLIEST" '
    any(.[];
        .name == "threshold reached" and .runID == $run and .creditAfter == 0 and
        ((.timestamp + 978307200) - $launch) >= $earliest
    )
' >/dev/null || fail "second callback event timestamp was earlier than the carryover-adjusted bound" 24

xcrun devicectl device process launch --device "$DEVICE" --terminate-existing \
    --json-output "$SESSION/final-shield-launch.json" com.rovio.baba >/dev/null
sleep 3
idevicescreenshot --udid "$UDID" "$SESSION/final-shield.png" >/dev/null
[[ -s "$SESSION/final-shield.png" ]] || fail "physical shield screenshot was not captured" 22
copy_state
require_ownership
json=$(state_json)
[[ $(print -rn -- "$json" | jq -r '[.creditSeconds,.isShielded,.thresholdReachedCount,.activeRunID] | @tsv') == $'0\ttrue\t2\t' ]] \
    || fail "final state changed after shield screenshot" 28

print "timing, ownership, negative control, and event checks passed" > "$SESSION/AUTOMATION_PASS"
print "Open final-shield.png and confirm the PagePass shield before creating PASS" > "$SESSION/SCREENSHOT_REVIEW_REQUIRED"
