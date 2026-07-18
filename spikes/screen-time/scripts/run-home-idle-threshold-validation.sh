#!/bin/zsh

set -eu
set -o pipefail
export PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"

if (( $# < 11 || $# > 12 )); then
    print -u2 "usage: $0 DEVICE UDID GROUP BUNDLE LEASE TAKEOVER_LEASE TAKEOVER_NONCE NONCE SESSION CREDIT IDLE_SECONDS [TARGET_BUNDLE]"
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
CREDIT=${10}
IDLE_SECONDS=${11}
TARGET_BUNDLE=${12:-com.rovio.baba}
CURRENT="$SESSION/current.plist"
SYSLOG="$SESSION/device-syslog.log"
CSV="$SESSION/samples.csv"
YEAR=$(date +%Y)

mkdir "$SESSION"
cp "${0:A}" "$SESSION/harness.sh"
shasum -a 256 "$SESSION/harness.sh" > "$SESSION/harness.sha256"
printf 'phase,sample,epoch,elapsed,credit,shielded,hits,run,event\n' > "$CSV"

fail() { print -r -- "$1" > "$SESSION/FAIL"; exit 1; }
copy_state() {
    rm -f "$CURRENT"
    xcrun devicectl device copy from --device "$DEVICE" \
        --domain-type appGroupDataContainer --domain-identifier "$GROUP" \
        --source "Library/Preferences/$GROUP.plist" --destination "$CURRENT" >/dev/null
}
state_json() { plutil -extract state raw -o - "$CURRENT" | base64 -D; }
events_json() { plutil -extract events raw -o - "$CURRENT" | base64 -D; }
owner_field() { plutil -extract automationOwnership raw -o - "$CURRENT" | base64 -D | jq -er ".$1"; }
require_owner() {
    [[ $(owner_field lease) == "$LEASE" ]] || fail "automation lease changed"
    [[ $(owner_field lastNonce) == "$NONCE" ]] || fail "automation nonce changed"
}
system_epoch() {
    print -r -- "$1" | YEAR="$YEAR" perl -MTime::Local -ne '
        my %month = (Jan=>0,Feb=>1,Mar=>2,Apr=>3,May=>4,Jun=>5,Jul=>6,Aug=>7,Sep=>8,Oct=>9,Nov=>10,Dec=>11);
        /^(\w{3})\s+(\d+)\s+(\d+):(\d+):(\d+)(?:\.(\d+))?/ or die "invalid syslog timestamp";
        my $fraction = defined($6) ? ("0.$6" + 0) : 0;
        printf "%.6f", timelocal($5,$4,$3,$2,$month{$1},$ENV{YEAR}-1900) + $fraction;
    '
}
wait_for_visibility() {
    local bundle=$1 first_line=$2 destination=$3 line="" attempt
    for (( attempt=1; attempt<=120; attempt++ )); do
        line=$(tail -n +$first_line "$SYSLOG" 2>/dev/null | awk -v bundle="$bundle" '
            index($0, "Application process state changed for " bundle ":") &&
            index($0, "visibility: Foreground") { print; exit }
        ' || true)
        if [[ -n "$line" ]]; then
            print -r -- "$line" > "$destination"
            system_epoch "$line"
            return
        fi
        sleep 0.5
    done
    fail "$bundle did not reach foreground"
}
append_sample() {
    local phase=$1 index=$2 start=$3 now elapsed json
    now=$(perl -MTime::HiRes=time -e 'printf "%.6f", time')
    elapsed=$(perl -e 'printf "%.3f", $ARGV[0]-$ARGV[1]' "$now" "$start")
    json=$(state_json)
    print "$phase,$index,$now,$elapsed,$(print -rn -- "$json" | jq -r '.creditSeconds,.isShielded,.thresholdReachedCount,(.activeRunID // "-"),(.activeEventName // "-")' | paste -sd, -)" >> "$CSV"
}
assert_target_not_foreground_since() {
    local first_line=$1 line
    line=$(tail -n +$first_line "$SYSLOG" 2>/dev/null | awk -v target="$TARGET_BUNDLE" '
        index($0, "Application process state changed for " target ":") &&
        index($0, "visibility: Foreground") { print; exit }
    ' || true)
    [[ -z "$line" ]] || {
        print -r -- "$line" > "$SESSION/unexpected-target-foreground.log"
        fail "The selected target became foreground during the non-target interval"
    }
}
capture_non_target_foreground_transitions() {
    local first_line=$1
    tail -n +$first_line "$SYSLOG" 2>/dev/null | awk '
        /Application process state changed for .*visibility: Foreground/ { print }
    ' > "$SESSION/non-target-foreground-transitions.log"
}
stop_syslog() {
    kill "$SYSLOG_PID" >/dev/null 2>&1 || true
    wait "$SYSLOG_PID" >/dev/null 2>&1 || true
}

idevicesyslog -u "$UDID" --no-colors \
    -p 'SpringBoard|runningboardd|backboardd|FrontBoard|UsageTrackingAgent' -o "$SYSLOG" &
SYSLOG_PID=$!
trap stop_syslog EXIT INT TERM
sleep 2

AUTOMATION_ARGUMENTS=(
    --pagepass-auto-legacy-proof
    --pagepass-auto-replace-run
    --pagepass-no-measurement-grace
    --pagepass-credit-seconds="$CREDIT"
    --pagepass-automation-lease="$LEASE"
    --pagepass-automation-nonce="$NONCE"
)
if [[ "$TAKEOVER_LEASE" != "-" || "$TAKEOVER_NONCE" != "-" ]]; then
    [[ "$TAKEOVER_LEASE" != "-" && "$TAKEOVER_NONCE" != "-" ]] \
        || fail "takeover lease and nonce must both be provided"
    AUTOMATION_ARGUMENTS+=(
        --pagepass-automation-takeover-from="$TAKEOVER_LEASE"
        --pagepass-automation-takeover-nonce="$TAKEOVER_NONCE"
    )
fi
xcrun devicectl device process launch --device "$DEVICE" --terminate-existing \
    --json-output "$SESSION/pagepass-launch.json" "$BUNDLE" \
    "${AUTOMATION_ARGUMENTS[@]}" >/dev/null

RUN=""
for _ in {1..30}; do
    sleep 1
    copy_state
    [[ $(owner_field lease 2>/dev/null || true) == "$LEASE" ]] || continue
    json=$(state_json)
    if [[ $(print -rn -- "$json" | jq -r '[.creditSeconds,.isShielded,.thresholdReachedCount,.intervalDidStart,.monitoringCompromised] | @tsv') == "$CREDIT"$'\tfalse\t0\ttrue\tfalse' ]]; then
        RUN=$(print -rn -- "$json" | jq -er '.activeRunID')
        break
    fi
done
[[ -n "$RUN" ]] || fail "Non-target interval run did not become ready"
for key in managedApps managedPolicyVersion appliedManagedPolicyVersion; do
    if plutil -extract "$key" raw -o - "$CURRENT" >/dev/null 2>&1; then
        fail "Legacy selection run unexpectedly retained PagePass parent-policy key: $key"
    fi
done
json=$(state_json)
[[ $(print -rn -- "$json" | jq -r '.enforcementMode') == "legacySelection" ]] \
    || fail "Run did not use legacySelection enforcement"
[[ $(print -rn -- "$json" | jq -r '.monitoringPolicyVersion // "none"') == "none" ]] \
    || fail "Legacy selection run unexpectedly referenced a managed policy version"
stored_selection=$(plutil -extract selection raw -o - "$CURRENT" | base64 -D | jq -Sc .)
monitoring_selection=$(plutil -extract monitoringSelection raw -o - "$CURRENT" | base64 -D | jq -Sc .)
[[ "$stored_selection" == "$monitoring_selection" ]] \
    || fail "Stored selection and monitoring selection differed"
jq -n \
    --arg enforcementMode "legacySelection" \
    --argjson managedPolicyKeysPresent false \
    --argjson monitoringPolicyVersion null \
    '{enforcementMode:$enforcementMode,managedPolicyKeysPresent:$managedPolicyKeysPresent,monitoringPolicyVersion:$monitoringPolicyVersion}' \
    > "$SESSION/pagepass-policy-state.json"
events=$(events_json)
provenance=$(print -rn -- "$events" | jq -er --arg lease "$LEASE" --arg nonce "$NONCE" '
    [.[] | select(
        .name == "automation binary provenance" and
        (.detail | contains("lease=" + $lease + "; generation=" + $nonce + ";"))
    ) | .detail] | last
')
app_hash=$(print -rn -- "$provenance" | sed -nE 's/.*app sha256=([0-9a-f]{64}).*/\1/p')
monitor_hash=$(print -rn -- "$provenance" | sed -nE 's/.*monitor sha256=([0-9a-f]{64}).*/\1/p')
[[ ${#app_hash} == 64 && ${#monitor_hash} == 64 ]] \
    || fail "Installed binary provenance was missing or malformed"
jq -n --arg appSHA256 "$app_hash" --arg monitorSHA256 "$monitor_hash" \
    '{appSHA256:$appSHA256,monitorSHA256:$monitorSHA256}' > "$SESSION/binary-provenance.json"
configuration=$(print -rn -- "$events" | jq -er --arg run "$RUN" '[.[] | select(.name == "monitoring registration verified" and .runID == $run) | .detail] | last')
armed=$(print -rn -- "$events" | jq -er --arg run "$RUN" '[.[] | select(.name == "monitoring start armed" and .runID == $run) | .detail] | last')
[[ "$configuration" == *"applications=1; categories=0; web domains=0; includesAllActivity=false"* ]] \
    || fail "event was not explicit-app-only: $configuration"
[[ "$configuration" == *"threshold=0h$(( CREDIT / 60 ))m$(( CREDIT % 60 ))s"* ]] \
    || fail "event threshold did not match ${CREDIT}s: $configuration"
[[ "$armed" == *"includesPastActivity=false"* ]] \
    || fail "event included past activity: $armed"
cp "$CURRENT" "$SESSION/initial-ready.plist"
plutil -extract selection raw -o - "$CURRENT" | base64 -D > "$SESSION/selection.json"
shasum -a 256 "$SESSION/selection.json" > "$SESSION/selection.sha256"

PAGEPASS_PID=$(jq -er '.result.process.processIdentifier' "$SESSION/pagepass-launch.json")
NON_TARGET_MARKER=$(( $(wc -l < "$SYSLOG") + 1 ))
xcrun devicectl device process terminate --device "$DEVICE" --pid "$PAGEPASS_PID" --kill \
    --json-output "$SESSION/pagepass-terminate.json" >/dev/null
sleep 3
NON_TARGET_START=$(perl -MTime::HiRes=time -e 'printf "%.6f", time')

i=0
CALLBACK_DURING_NON_TARGET=false
while true; do
    now=$(perl -MTime::HiRes=time -e 'printf "%.6f", time')
    elapsed=$(perl -e 'printf "%.3f", $ARGV[0]-$ARGV[1]' "$now" "$NON_TARGET_START")
    jq -en --argjson elapsed "$elapsed" --argjson limit "$IDLE_SECONDS" '$elapsed >= $limit' >/dev/null && break
    sleep 5
    copy_state
    require_owner
    assert_target_not_foreground_since "$NON_TARGET_MARKER"
    append_sample non-target "$i" "$NON_TARGET_START"
    json=$(state_json)
    credit=$(print -rn -- "$json" | jq -er '.creditSeconds')
    hits=$(print -rn -- "$json" | jq -er '.thresholdReachedCount')
    shielded=$(print -rn -- "$json" | jq -r '.isShielded')
    if [[ "$credit" == 0 && "$hits" == 1 && "$shielded" == true ]]; then
        CALLBACK_DURING_NON_TARGET=true
        break
    fi
    [[ "$credit" == "$CREDIT" && "$hits" == 0 && "$shielded" == false ]] \
        || fail "Non-target interval entered an invalid state"
    i=$((i + 1))
done

if [[ "$CALLBACK_DURING_NON_TARGET" == true ]]; then
    capture_non_target_foreground_transitions "$NON_TARGET_MARKER"
    CALLBACK_EPOCH=$(events_json | jq -er --arg run "$RUN" '[.[] | select(.name == "threshold reached" and .runID == $run and .creditAfter == 0) | (.timestamp + 978307200)] | last')
    NON_TARGET_CALLBACK_SECONDS=$(perl -e 'printf "%.3f", $ARGV[0]-$ARGV[1]' "$CALLBACK_EPOCH" "$NON_TARGET_START")
    jq -n --arg run "$RUN" --arg outcome "callback-during-non-target" --arg idle "$NON_TARGET_CALLBACK_SECONDS" --arg configuration "$configuration" \
        '{runID:$run,outcome:$outcome,nonTargetSecondsBeforeCallback:($idle|tonumber),eventConfiguration:$configuration}' > "$SESSION/result.json"
    print "Threshold callback arrived before the selected target became foreground" > "$SESSION/NON_TARGET_CALLBACK"
    exit 0
fi

copy_state
require_owner
assert_target_not_foreground_since "$NON_TARGET_MARKER"
json=$(state_json)
[[ $(print -rn -- "$json" | jq -r '[.creditSeconds,.isShielded,.thresholdReachedCount] | @tsv') == "$CREDIT"$'\tfalse\t0' ]] \
    || fail "Non-target interval changed state at the final boundary"
append_sample non-target-final "$i" "$NON_TARGET_START"
capture_non_target_foreground_transitions "$NON_TARGET_MARKER"
cp "$CURRENT" "$SESSION/non-target-complete.plist"
NON_TARGET_SECONDS=$(perl -MTime::HiRes=time -e 'printf "%.3f", time - $ARGV[0]' "$NON_TARGET_START")

TARGET_MARKER=$(( $(wc -l < "$SYSLOG") + 1 ))
xcrun devicectl device process launch --device "$DEVICE" --terminate-existing \
    --json-output "$SESSION/target-launch.json" "$TARGET_BUNDLE" >/dev/null
TARGET_START=$(wait_for_visibility "$TARGET_BUNDLE" "$TARGET_MARKER" "$SESSION/target-foreground.log")

i=0
while true; do
    sleep 1
    copy_state
    require_owner
    append_sample target "$i" "$TARGET_START"
    json=$(state_json)
    credit=$(print -rn -- "$json" | jq -er '.creditSeconds')
    hits=$(print -rn -- "$json" | jq -er '.thresholdReachedCount')
    shielded=$(print -rn -- "$json" | jq -r '.isShielded')
    if [[ "$credit" == 0 && "$hits" == 1 && "$shielded" == true ]]; then
        CALLBACK_EPOCH=$(events_json | jq -er --arg run "$RUN" '[.[] | select(.name == "threshold reached" and .runID == $run and .creditAfter == 0) | (.timestamp + 978307200)] | last')
        TARGET_SECONDS=$(perl -e 'printf "%.3f", $ARGV[0]-$ARGV[1]' "$CALLBACK_EPOCH" "$TARGET_START")
        jq -en --argjson delta "$TARGET_SECONDS" '$delta >= 0' >/dev/null \
            || fail "Threshold callback timestamp preceded target foreground"
        break
    fi
    [[ "$credit" == "$CREDIT" && "$hits" == 0 && "$shielded" == false ]] \
        || fail "target phase entered an invalid state"
    now=$(perl -MTime::HiRes=time -e 'printf "%.6f", time')
    elapsed=$(perl -e 'printf "%.3f", $ARGV[0]-$ARGV[1]' "$now" "$TARGET_START")
    jq -en --argjson elapsed "$elapsed" --argjson limit "$((CREDIT + 120))" '$elapsed < $limit' >/dev/null \
        || fail "target callback timed out"
    i=$((i + 1))
done

cp "$CURRENT" "$SESSION/final-state.plist"
events_json > "$SESSION/events.json"
jq -n --arg run "$RUN" --arg outcome "callback-after-target-open" --arg idle "$NON_TARGET_SECONDS" --arg target "$TARGET_SECONDS" --arg targetBundle "$TARGET_BUNDLE" --arg configuration "$configuration" \
    '{runID:$run,outcome:$outcome,targetBundle:$targetBundle,nonTargetSeconds:($idle|tonumber),targetSecondsBeforeCallback:($target|tonumber),eventConfiguration:$configuration}' > "$SESSION/result.json"
print "Non-target interval completed; callback arrived after target foreground" > "$SESSION/AUTOMATION_COMPLETE"
