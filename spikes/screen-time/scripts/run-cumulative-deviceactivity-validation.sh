#!/bin/zsh

set -eu
set -o pipefail
export PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:$HOME/Library/Python/3.9/bin"

if (( $# != 12 )); then
    print -u2 "usage: $0 DEVICE UDID GROUP BUNDLE LEASE TAKEOVER_LEASE TAKEOVER_NONCE NONCE SESSION_DIR CREDIT_SECONDS QUANTUM_SECONDS NOTES_SECONDS"
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
CREDIT_SECONDS=${10}
QUANTUM_SECONDS=${11}
NOTES_DURATION_SECONDS=${12}
MEASUREMENT_GRACE_SECONDS=60
FIRST_PHYSICAL_THRESHOLD=$((QUANTUM_SECONDS + MEASUREMENT_GRACE_SECONDS))
(( CREDIT_SECONDS == QUANTUM_SECONDS * 3 )) \
    || { print -u2 "validation requires exactly three equal quanta"; exit 64; }

CURRENT="$SESSION/current.plist"
CSV="$SESSION/samples.csv"
STARTED_AT=$(date +%s)
mkdir "$SESSION"
printf 'phase,sample,epoch,elapsed,credit,shielded,hits,run,event,lease\n' > "$CSV"
jq -n \
    --arg device "$DEVICE" --arg udid "$UDID" --arg group "$GROUP" \
    --arg bundle "$BUNDLE" --arg lease "$LEASE" --arg takeover "$TAKEOVER_LEASE" \
    --arg takeoverNonce "$TAKEOVER_NONCE" --arg nonce "$NONCE" \
    --argjson startedAt "$STARTED_AT" --argjson credit "$CREDIT_SECONDS" \
    --argjson quantum "$QUANTUM_SECONDS" --argjson notes "$NOTES_DURATION_SECONDS" \
    --argjson grace "$MEASUREMENT_GRACE_SECONDS" \
    '{device:$device,udid:$udid,group:$group,bundle:$bundle,lease:$lease,takeoverLease:$takeover,takeoverNonce:$takeoverNonce,nonce:$nonce,startedAt:$startedAt,creditSeconds:$credit,quantumSeconds:$quantum,notesDurationSeconds:$notes,oneTimeGraceSeconds:$grace}' \
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
    [[ "$actual_lease" == "$LEASE" ]] || fail "lease changed to $actual_lease" 10
    [[ "$actual_nonce" == "$NONCE" ]] || fail "generation changed to $actual_nonce" 11
}

append_sample() {
    local phase=$1 sample=$2 started=$3
    local now elapsed json credit shielded hits run event actual_lease
    now=$(date +%s)
    elapsed=$((now - started))
    json=$(state_json)
    credit=$(print -rn -- "$json" | jq -er '.creditSeconds')
    shielded=$(print -rn -- "$json" | jq -r '.isShielded')
    hits=$(print -rn -- "$json" | jq -er '.thresholdReachedCount')
    run=$(print -rn -- "$json" | jq -r '.activeRunID // "-"')
    event=$(print -rn -- "$json" | jq -r '.activeEventName // "-"')
    actual_lease=$(owner_field lease)
    print "$phase,$sample,$now,$elapsed,$credit,$shielded,$hits,$run,$event,$actual_lease" >> "$CSV"
}

threshold_epoch() {
    local run=$1 credit_after=$2
    events_json | jq -er --arg run "$run" --argjson credit "$credit_after" '
        [.[] | select(.name == "threshold reached" and .runID == $run and .creditAfter == $credit) | (.timestamp + 978307200)] | last
    '
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

xcrun devicectl device process launch --device "$DEVICE" --terminate-existing \
    --json-output "$SESSION/pagepass-launch.json" "$BUNDLE" \
    --pagepass-auto-managed-proof --pagepass-auto-replace-run \
    --pagepass-credit-seconds="$CREDIT_SECONDS" --pagepass-quantum-seconds="$QUANTUM_SECONDS" \
    --pagepass-automation-lease="$LEASE" --pagepass-automation-nonce="$NONCE" \
    --pagepass-automation-takeover-from="$TAKEOVER_LEASE" \
    --pagepass-automation-takeover-nonce="$TAKEOVER_NONCE" >/dev/null

RUN_ID=""
for _ in {1..30}; do
    sleep 1
    copy_state
    actual_lease=$(owner_field lease 2>/dev/null || true)
    actual_nonce=$(owner_field lastNonce 2>/dev/null || true)
    [[ "$actual_lease" == "$LEASE" && "$actual_nonce" == "$NONCE" ]] || continue
    json=$(state_json)
    values=$(print -rn -- "$json" | jq -r '[.creditSeconds,.isShielded,.thresholdReachedCount,.intervalDidStart,.monitoringCompromised] | @tsv')
    if [[ "$values" == "$CREDIT_SECONDS"$'\tfalse\t0\ttrue\tfalse' ]]; then
        RUN_ID=$(print -rn -- "$json" | jq -er '.activeRunID')
        break
    fi
done
[[ -n "$RUN_ID" ]] || fail "cumulative run did not become ready" 12
cp "$CURRENT" "$SESSION/initial-ready.plist"
jq --arg run "$RUN_ID" '.runID=$run' "$SESSION/manifest.json" > "$SESSION/manifest.next"
mv "$SESSION/manifest.next" "$SESSION/manifest.json"

FIRST_START=$(date +%s)
xcrun devicectl device process launch --device "$DEVICE" --terminate-existing \
    --json-output "$SESSION/angry1-launch.json" com.rovio.baba >/dev/null
sample=0
while true; do
    elapsed=$(($(date +%s) - FIRST_START))
    (( elapsed < QUANTUM_SECONDS )) && sleep 5 || sleep 0.2
    copy_state
    require_ownership
    append_sample angry1 "$sample" "$FIRST_START"
    json=$(state_json)
    [[ $(print -rn -- "$json" | jq -r '.thresholdDebitPending') == false ]] \
        || fail "first callback left a pending debit marker" 13
    hits=$(print -rn -- "$json" | jq -er '.thresholdReachedCount')
    if (( hits == 1 )); then
        values=$(print -rn -- "$json" | jq -r '[.creditSeconds,.isShielded,.activeRunID,.monitoringCompromised] | @tsv')
        [[ "$values" == "$((CREDIT_SECONDS - QUANTUM_SECONDS))"$'\tfalse\t'"$RUN_ID"$'\tfalse' ]] \
            || fail "first cumulative debit produced an invalid state" 14
        FIRST_CALLBACK_AT=$(threshold_epoch "$RUN_ID" "$((CREDIT_SECONDS - QUANTUM_SECONDS))")
        FIRST_EVENT_DELTA=$(perl -e 'printf "%.6f", $ARGV[0] - $ARGV[1]' "$FIRST_CALLBACK_AT" "$FIRST_START")
        jq -en --argjson delta "$FIRST_EVENT_DELTA" --argjson floor "$QUANTUM_SECONDS" '$delta >= $floor' >/dev/null \
            || fail "first callback event was before the logical floor: ${FIRST_EVENT_DELTA}s" 15
        break
    fi
    (( hits == 0 )) || fail "first phase skipped a cumulative threshold" 16
    (( elapsed < FIRST_PHYSICAL_THRESHOLD + 160 )) || fail "first callback timed out" 17
    sample=$((sample + 1))
done
cp "$CURRENT" "$SESSION/first-threshold.plist"

NOTES_REQUEST_AT=$(perl -MTime::HiRes=time -e 'printf "%.6f", time')
xcrun devicectl device process launch --device "$DEVICE" --terminate-existing \
    --json-output "$SESSION/notes-launch.json" com.apple.mobilenotes >/dev/null
NOTES_CONFIRMED_AT=$(perl -MTime::HiRes=time -e 'printf "%.6f", time')
NOTES_START=$(date +%s)
CARRYOVER_UPPER=$(perl -e 'my $v=$ARGV[0]-$ARGV[1]; $v=0 if $v<0; printf "%.6f",$v' "$NOTES_CONFIRMED_AT" "$FIRST_CALLBACK_AT")
xcrun devicectl device info processes --device "$DEVICE" \
    --json-output "$SESSION/processes-before-notes.json" >/dev/null
ANGRY_PID=$(jq -er '.. | objects | select((.executable? // "") | contains("AngryBirds2.app")) | .processIdentifier' "$SESSION/processes-before-notes.json" | head -1 || true)
if [[ -n "$ANGRY_PID" ]]; then
    xcrun devicectl device process terminate --device "$DEVICE" --pid "$ANGRY_PID" --kill >/dev/null
fi

sample=0
while (( $(date +%s) - NOTES_START < NOTES_DURATION_SECONDS )); do
    sleep 5
    copy_state
    require_ownership
    append_sample notes "$sample" "$NOTES_START"
    json=$(state_json)
    values=$(print -rn -- "$json" | jq -r '[.creditSeconds,.isShielded,.thresholdReachedCount,.activeRunID,.monitoringCompromised] | @tsv')
    [[ "$values" == "$((CREDIT_SECONDS - QUANTUM_SECONDS))"$'\tfalse\t1\t'"$RUN_ID"$'\tfalse' ]] \
        || fail "Notes changed the cumulative run" 18
    sample=$((sample + 1))
done
cp "$CURRENT" "$SESSION/notes-complete.plist"

SECOND_EARLIEST=$(perl -MPOSIX=ceil -e 'my $v=$ARGV[0]-ceil($ARGV[1])-2; $v=0 if $v<0; print $v' "$QUANTUM_SECONDS" "$CARRYOVER_UPPER")
SECOND_START=$(date +%s)
xcrun devicectl device process launch --device "$DEVICE" --terminate-existing \
    --json-output "$SESSION/angry2-launch.json" com.rovio.baba >/dev/null
sample=0
while true; do
    sleep 1
    copy_state
    require_ownership
    append_sample angry2 "$sample" "$SECOND_START"
    json=$(state_json)
    hits=$(print -rn -- "$json" | jq -er '.thresholdReachedCount')
    elapsed=$(($(date +%s) - SECOND_START))
    if (( hits == 2 )); then
        values=$(print -rn -- "$json" | jq -r '[.creditSeconds,.isShielded,.activeRunID,.monitoringCompromised] | @tsv')
        [[ "$values" == "$QUANTUM_SECONDS"$'\tfalse\t'"$RUN_ID"$'\tfalse' ]] \
            || fail "second cumulative debit produced an invalid state" 19
        SECOND_CALLBACK_AT=$(threshold_epoch "$RUN_ID" "$QUANTUM_SECONDS")
        SECOND_EVENT_DELTA=$(perl -e 'printf "%.6f", $ARGV[0] - $ARGV[1]' "$SECOND_CALLBACK_AT" "$SECOND_START")
        jq -en --argjson delta "$SECOND_EVENT_DELTA" --argjson earliest "$SECOND_EARLIEST" '$delta >= $earliest' >/dev/null \
            || fail "second callback was early: ${SECOND_EVENT_DELTA}s, carryover upper ${CARRYOVER_UPPER}s" 20
        break
    fi
    (( hits == 1 )) || fail "second phase skipped a cumulative threshold" 21
    (( elapsed < QUANTUM_SECONDS + 160 )) || fail "second callback timed out" 22
    sample=$((sample + 1))
done
cp "$CURRENT" "$SESSION/second-threshold.plist"

sample=0
while true; do
    sleep 1
    copy_state
    require_ownership
    append_sample angry3 "$sample" "$SECOND_CALLBACK_AT"
    json=$(state_json)
    credit=$(print -rn -- "$json" | jq -er '.creditSeconds')
    shielded=$(print -rn -- "$json" | jq -r '.isShielded')
    hits=$(print -rn -- "$json" | jq -er '.thresholdReachedCount')
    run=$(print -rn -- "$json" | jq -r '.activeRunID // "-"')
    if [[ "$credit" == 0 && "$shielded" == true && "$hits" == 3 && "$run" == "-" ]]; then
        THIRD_CALLBACK_AT=$(threshold_epoch "$RUN_ID" 0)
        THIRD_EVENT_DELTA=$(perl -e 'printf "%.6f", $ARGV[0] - $ARGV[1]' "$THIRD_CALLBACK_AT" "$SECOND_CALLBACK_AT")
        jq -en --argjson delta "$THIRD_EVENT_DELTA" --argjson floor "$QUANTUM_SECONDS" '$delta >= ($floor - 2)' >/dev/null \
            || fail "third callback was early: ${THIRD_EVENT_DELTA}s" 23
        break
    fi
    [[ "$credit" == "$QUANTUM_SECONDS" && "$shielded" == false && "$hits" == 2 && "$run" == "$RUN_ID" ]] \
        || fail "third phase changed before the final threshold" 24
    sample=$((sample + 1))
done
cp "$CURRENT" "$SESSION/final-state.plist"

jq --argjson first "$FIRST_EVENT_DELTA" --argjson carryover "$CARRYOVER_UPPER" \
    --argjson second "$SECOND_EVENT_DELTA" --argjson third "$THIRD_EVENT_DELTA" \
    '.firstEventDelta=$first | .carryoverUpperSeconds=$carryover | .secondEventDelta=$second | .thirdEventDelta=$third' \
    "$SESSION/manifest.json" > "$SESSION/manifest.next"
mv "$SESSION/manifest.next" "$SESSION/manifest.json"

xcrun devicectl device process launch --device "$DEVICE" --terminate-existing \
    --json-output "$SESSION/final-shield-launch.json" com.rovio.baba >/dev/null
sleep 2
idb screenshot --udid "$UDID" "$SESSION/final-shield.png" >/dev/null 2>&1 || true
copy_state
require_ownership
json=$(state_json)
[[ $(print -rn -- "$json" | jq -r '[.creditSeconds,.isShielded,.thresholdReachedCount,.activeRunID] | @tsv') == $'0\ttrue\t3\t' ]] \
    || fail "final state changed after launching the shielded app" 25

print "cumulative timing, Notes isolation, ownership, and final Shield state passed" > "$SESSION/AUTOMATION_PASS"
