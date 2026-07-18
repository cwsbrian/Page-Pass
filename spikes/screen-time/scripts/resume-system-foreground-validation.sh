#!/bin/zsh

set -eu
set -o pipefail
export PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"

if (( $# < 10 || $# > 12 )); then
    print -u2 "usage: $0 DEVICE UDID GROUP BUNDLE LEASE NONCE SESSION CREDIT NOTES_SECONDS MAX_TARGET_SECONDS [PRIOR_TARGET_SECONDS] [automatic|manual]"
    exit 64
fi

DEVICE=$1
UDID=$2
GROUP=$3
BUNDLE=$4
LEASE=$5
NONCE=$6
SESSION=$7
CREDIT=$8
NOTES_SECONDS=$9
MAX_TARGET_SECONDS=${10}
PRIOR_TARGET_SECONDS=${11:-0}
TRANSITION_MODE=${12:-automatic}
[[ "$TRANSITION_MODE" == automatic || "$TRANSITION_MODE" == manual ]] \
    || { print -u2 "transition mode must be automatic or manual"; exit 64; }
VISIBILITY_POLLS=60
[[ "$TRANSITION_MODE" == manual ]] && VISIBILITY_POLLS=600
REMAINING_FLOOR=$(perl -e '$v=$ARGV[0]-$ARGV[1]-5; printf "%.3f", $v > 0 ? $v : 0' "$CREDIT" "$PRIOR_TARGET_SECONDS")
CURRENT="$SESSION/resumed-current.plist"
SYSLOG="$SESSION/resumed-device-syslog.log"
CSV="$SESSION/resumed-samples.csv"
YEAR=$(date +%Y)

printf 'phase,sample,epoch,systemForegroundElapsed,credit,shielded,hits,run,event\n' > "$CSV"

fail() { print -r -- "$1" > "$SESSION/RESUMED_FAIL"; exit 1; }
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
        /^(\w+)\s+(\d+)\s+(\d+):(\d+):(\d+)(?:\.(\d+))?/ or die "invalid syslog timestamp";
        my $fraction = defined($6) ? ("0.$6" + 0) : 0;
        printf "%.6f", timelocal($5,$4,$3,$2,$month{$1},$ENV{YEAR}-1900) + $fraction;
    '
}
wait_for_visibility() {
    local bundle=$1 visibility=$2 first_line=$3 destination=$4
    local line="" attempt
    for (( attempt=1; attempt<=VISIBILITY_POLLS; attempt++ )); do
        line=$(tail -n +$first_line "$SYSLOG" 2>/dev/null | awk -v bundle="$bundle" -v visibility="$visibility" '
            (index($0, "Application process state changed for " bundle ":") && index($0, "visibility: " visibility)) ||
            (visibility == "Foreground" && index($0, "app<" bundle) && index($0, "running-active-Visible")) { print; exit }
        ' || true)
        if [[ -n "$line" ]]; then
            print -r -- "$line" > "$destination"
            system_epoch "$line"
            return
        fi
        sleep 0.5
    done
    fail "$bundle did not reach system visibility $visibility"
}
append_sample() {
    local phase=$1 index=$2 foreground_epoch=$3 now json elapsed
    now=$(perl -MTime::HiRes=time -e 'printf "%.6f", time')
    elapsed=$(perl -e 'printf "%.3f", $ARGV[0]-$ARGV[1]' "$now" "$foreground_epoch")
    json=$(state_json)
    print "$phase,$index,$now,$elapsed,$(print -rn -- "$json" | jq -r '.creditSeconds,.isShielded,.thresholdReachedCount,(.activeRunID // "-"),(.activeEventName // "-")' | paste -sd, -)" >> "$CSV"
}
stop_syslog() {
    kill "$SYSLOG_PID" >/dev/null 2>&1 || true
    wait "$SYSLOG_PID" >/dev/null 2>&1 || true
}

copy_state
require_owner
json=$(state_json)
RUN=$(print -rn -- "$json" | jq -er '.activeRunID')
[[ $(print -rn -- "$json" | jq -r '[.creditSeconds,.isShielded,.thresholdReachedCount,.intervalDidStart,.monitoringCompromised] | @tsv') == "$CREDIT"$'\tfalse\t0\ttrue\tfalse' ]] \
    || fail "resumed run was not ready"
configuration=$(events_json | jq -er --arg run "$RUN" '[.[] | select(.name == "monitoring registration verified" and .runID == $run) | .detail] | last')
[[ "$configuration" == *"applications=1; categories=0; web domains=0; includesAllActivity=false"* ]] \
    || fail "resumed event was not explicit-app-only: $configuration"

idevicesyslog -u "$UDID" --no-colors \
    -p 'SpringBoard|runningboardd|backboardd|FrontBoard' -o "$SYSLOG" &
SYSLOG_PID=$!
trap stop_syslog EXIT INT TERM
sleep 2

marker=$(( $(wc -l < "$SYSLOG") + 1 ))
if [[ "$TRANSITION_MODE" == manual ]]; then
    NOTES_FOREGROUND=$(perl -MTime::HiRes=time -e 'printf "%.6f", time')
else
    xcrun devicectl device process launch --device "$DEVICE" --terminate-existing \
        --json-output "$SESSION/resumed-notes-launch.json" com.apple.mobilenotes >/dev/null
    NOTES_FOREGROUND=$(wait_for_visibility com.apple.mobilenotes Foreground "$marker" "$SESSION/resumed-notes-foreground.log")
fi

i=0
while true; do
    now=$(perl -MTime::HiRes=time -e 'printf "%.6f", time')
    elapsed=$(perl -e 'printf "%.3f", $ARGV[0]-$ARGV[1]' "$now" "$NOTES_FOREGROUND")
    jq -en --argjson elapsed "$elapsed" --argjson limit "$NOTES_SECONDS" '$elapsed >= $limit' >/dev/null && break
    sleep 30
    copy_state
    require_owner
    append_sample notes "$i" "$NOTES_FOREGROUND"
    json=$(state_json)
    [[ $(print -rn -- "$json" | jq -r '[.creditSeconds,.isShielded,.thresholdReachedCount,.activeRunID] | @tsv') == "$CREDIT"$'\tfalse\t0\t'"$RUN" ]] \
        || fail "Notes changed the fresh local explicit-app event before ${NOTES_SECONDS}s"
    i=$((i + 1))
done
copy_state
require_owner
append_sample notes-final "$i" "$NOTES_FOREGROUND"
json=$(state_json)
[[ $(print -rn -- "$json" | jq -r '[.creditSeconds,.isShielded,.thresholdReachedCount,.activeRunID] | @tsv') == "$CREDIT"$'\tfalse\t0\t'"$RUN" ]] \
    || fail "Notes consumed credit during the full fresh local negative control"

marker=$(( $(wc -l < "$SYSLOG") + 1 ))
if [[ "$TRANSITION_MODE" == manual ]]; then
    print "ACTION: On the iPhone, tap the Angry Birds 2 icon now. Do not use the Mac or app switcher."
else
    xcrun devicectl device process launch --device "$DEVICE" --terminate-existing \
        --json-output "$SESSION/resumed-angry-launch.json" com.rovio.baba >/dev/null
fi
ANGRY_FOREGROUND=$(wait_for_visibility com.rovio.baba Foreground "$marker" "$SESSION/resumed-angry-foreground.log")

i=0
while true; do
    if [[ "$TRANSITION_MODE" == manual ]]; then
        sleep 1
    else
        sleep 15
    fi
    copy_state
    require_owner
    append_sample angry "$i" "$ANGRY_FOREGROUND"
    json=$(state_json)
    credit=$(print -rn -- "$json" | jq -er '.creditSeconds')
    hits=$(print -rn -- "$json" | jq -er '.thresholdReachedCount')
    shielded=$(print -rn -- "$json" | jq -r '.isShielded')
    if [[ "$credit" == 0 && "$hits" == 1 && "$shielded" == true ]]; then
        CALLBACK_EPOCH=$(events_json | jq -er --arg run "$RUN" '[.[] | select(.name == "threshold reached" and .runID == $run and .creditAfter == 0) | (.timestamp + 978307200)] | last')
        TARGET_SECONDS=$(perl -e 'printf "%.3f", $ARGV[0]-$ARGV[1]' "$CALLBACK_EPOCH" "$ANGRY_FOREGROUND")
        jq -en --argjson value "$TARGET_SECONDS" --argjson floor "$REMAINING_FLOOR" --argjson ceiling "$MAX_TARGET_SECONDS" '$value >= $floor and $value <= $ceiling' >/dev/null \
            || fail "fresh local resumed Angry usage was ${TARGET_SECONDS}s; accepted ${REMAINING_FLOOR}...${MAX_TARGET_SECONDS}s after ${PRIOR_TARGET_SECONDS}s prior use"
        break
    fi
    [[ "$credit" == "$CREDIT" && "$hits" == 0 && "$shielded" == false ]] \
        || fail "fresh local target phase entered an invalid intermediate state"
    i=$((i + 1))
done

cp "$CURRENT" "$SESSION/resumed-final-state.plist"
events_json > "$SESSION/resumed-events.json"
jq -n --arg run "$RUN" --arg notesForeground "$NOTES_FOREGROUND" --arg angryForeground "$ANGRY_FOREGROUND" \
    --arg callback "$CALLBACK_EPOCH" --arg targetSeconds "$TARGET_SECONDS" --arg priorTargetSeconds "$PRIOR_TARGET_SECONDS" --arg configuration "$configuration" --arg mode "$TRANSITION_MODE" \
    '{runID:$run,transitionMode:$mode,notesForegroundEpoch:($notesForeground|tonumber),angryForegroundEpoch:($angryForeground|tonumber),callbackEpoch:($callback|tonumber),priorSystemTimedAngrySeconds:($priorTargetSeconds|tonumber),resumedSystemTimedAngrySeconds:($targetSeconds|tonumber),totalSystemTimedAngrySeconds:(($priorTargetSeconds|tonumber)+($targetSeconds|tonumber)),eventConfiguration:$configuration}' \
    > "$SESSION/resumed-result.json"
print "Fresh local SpringBoard-timed validation passed" > "$SESSION/RESUMED_AUTOMATION_PASS"
