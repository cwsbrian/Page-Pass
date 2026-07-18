#!/bin/zsh

set -eu
set -o pipefail
export PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"

if (( $# < 13 || $# > 14 )); then
    print -u2 "usage: $0 DEVICE UDID GROUP BUNDLE LEASE TAKEOVER_LEASE TAKEOVER_NONCE NONCE SESSION CREDIT NOTES_SECONDS GRACE MAX_TARGET_SECONDS [managed|legacy|legacy-exact|legacy-all-except]"
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
NOTES_SECONDS=${11}
GRACE=${12}
MAX_TARGET_SECONDS=${13}
MODE=${14:-managed}
CURRENT="$SESSION/current.plist"
SYSLOG="$SESSION/device-syslog.log"
CSV="$SESSION/samples.csv"
YEAR=$(date +%Y)

mkdir "$SESSION"
printf 'phase,sample,epoch,systemForegroundElapsed,credit,shielded,hits,run,event\n' > "$CSV"

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
        /^(\w+)\s+(\d+)\s+(\d+):(\d+):(\d+)(?:\.(\d+))?/ or die "invalid syslog timestamp";
        my $fraction = defined($6) ? ("0.$6" + 0) : 0;
        printf "%.6f", timelocal($5,$4,$3,$2,$month{$1},$ENV{YEAR}-1900) + $fraction;
    '
}
wait_for_visibility() {
    local bundle=$1 visibility=$2 first_line=$3 destination=$4
    local line=""
    for _ in {1..60}; do
        line=$(tail -n +$first_line "$SYSLOG" 2>/dev/null | awk -v bundle="$bundle" -v visibility="$visibility" '
            index($0, "Application process state changed for " bundle ":") && index($0, "visibility: " visibility) { print; exit }
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

idevicesyslog -u "$UDID" --no-colors \
    -p 'SpringBoard|runningboardd|backboardd|FrontBoard' -o "$SYSLOG" &
SYSLOG_PID=$!
trap stop_syslog EXIT INT TERM
sleep 2

xcrun devicectl device process launch --device "$DEVICE" --terminate-existing \
    --json-output "$SESSION/baseline-notes.json" com.apple.mobilenotes >/dev/null
sleep 1
case "$MODE" in
    managed)
        automation_arguments=(--pagepass-auto-managed-proof --pagepass-auto-replace-run)
        ;;
    legacy)
        automation_arguments=(--pagepass-auto-legacy-proof)
        ;;
    legacy-exact)
        automation_arguments=(--pagepass-auto-legacy-proof --pagepass-no-measurement-grace)
        ;;
    legacy-all-except)
        automation_arguments=(--pagepass-auto-legacy-proof --pagepass-no-measurement-grace --pagepass-diagnostic-all-except-shield)
        ;;
    *)
        fail "unsupported automation mode: $MODE"
        ;;
esac
automation_arguments+=(
    --pagepass-credit-seconds="$CREDIT"
    --pagepass-quantum-seconds="$CREDIT"
    --pagepass-automation-lease="$LEASE"
    --pagepass-automation-nonce="$NONCE"
)
if [[ "$TAKEOVER_LEASE" != "-" || "$TAKEOVER_NONCE" != "-" ]]; then
    [[ "$TAKEOVER_LEASE" != "-" && "$TAKEOVER_NONCE" != "-" ]] \
        || fail "takeover lease and nonce must both be provided"
    automation_arguments+=(
        --pagepass-automation-takeover-from="$TAKEOVER_LEASE"
        --pagepass-automation-takeover-nonce="$TAKEOVER_NONCE"
    )
fi
xcrun devicectl device process launch --device "$DEVICE" --terminate-existing \
    --json-output "$SESSION/pagepass-launch.json" "$BUNDLE" \
    "${automation_arguments[@]}" >/dev/null

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
[[ -n "$RUN" ]] || fail "long single-event $MODE run did not become ready"
events=$(events_json)
configuration=$(print -rn -- "$events" | jq -er --arg run "$RUN" '[.[] | select(.name == "monitoring start armed" and .runID == $run) | .detail] | last')
[[ "$configuration" == *"applications=1; categories=0; web domains=0; includesAllActivity=false"* ]] \
    || fail "registered event was not explicit-app-only: $configuration"
[[ "$configuration" == *"includesPastActivity=false"* ]] \
    || fail "registered event included past activity"
if [[ "$MODE" == legacy-exact || "$MODE" == legacy-all-except ]]; then
    expected_hours=$(( CREDIT / 3600 ))
    expected_minutes=$(( (CREDIT % 3600) / 60 ))
    expected_seconds=$(( CREDIT % 60 ))
    expected_threshold="threshold=${expected_hours}h${expected_minutes}m${expected_seconds}s"
    [[ "$configuration" == *"$expected_threshold"* ]] \
        || fail "exact diagnostic threshold mismatch; expected $expected_threshold: $configuration"
fi
cp "$CURRENT" "$SESSION/initial-ready.plist"

marker=$(( $(wc -l < "$SYSLOG") + 1 ))
xcrun devicectl device process launch --device "$DEVICE" --terminate-existing \
    --json-output "$SESSION/notes-launch.json" com.apple.mobilenotes >/dev/null
NOTES_FOREGROUND=$(wait_for_visibility com.apple.mobilenotes Foreground "$marker" "$SESSION/notes-foreground.log")

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
        || fail "Notes changed the explicit-app event before ${NOTES_SECONDS}s"
    i=$((i + 1))
done
copy_state
require_owner
append_sample notes-final "$i" "$NOTES_FOREGROUND"
json=$(state_json)
[[ $(print -rn -- "$json" | jq -r '[.creditSeconds,.isShielded,.thresholdReachedCount,.activeRunID] | @tsv') == "$CREDIT"$'\tfalse\t0\t'"$RUN" ]] \
    || fail "Notes consumed credit during the full negative control"
cp "$CURRENT" "$SESSION/notes-complete.plist"

marker=$(( $(wc -l < "$SYSLOG") + 1 ))
xcrun devicectl device process launch --device "$DEVICE" --terminate-existing \
    --json-output "$SESSION/angry-launch.json" com.rovio.baba >/dev/null
ANGRY_FOREGROUND=$(wait_for_visibility com.rovio.baba Foreground "$marker" "$SESSION/angry-foreground.log")

i=0
while true; do
    sleep 15
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
        jq -en --argjson value "$TARGET_SECONDS" --argjson floor "$CREDIT" --argjson ceiling "$MAX_TARGET_SECONDS" '$value >= $floor and $value <= $ceiling' >/dev/null \
            || fail "system-timed Angry usage was ${TARGET_SECONDS}s; accepted ${CREDIT}...${MAX_TARGET_SECONDS}s"
        break
    fi
    [[ "$credit" == "$CREDIT" && "$hits" == 0 && "$shielded" == false ]] \
        || fail "long target phase entered an invalid intermediate state"
    i=$((i + 1))
done

cp "$CURRENT" "$SESSION/final-state.plist"
events_json > "$SESSION/events.json"
grep -E 'Application process state changed for (com.apple.mobilenotes|com.rovio.baba|com.pagepass.controlspike)' "$SYSLOG" > "$SESSION/system-visibility-events.log" || true
jq -n --arg run "$RUN" --arg notesForeground "$NOTES_FOREGROUND" --arg angryForeground "$ANGRY_FOREGROUND" \
    --arg callback "$CALLBACK_EPOCH" --arg targetSeconds "$TARGET_SECONDS" --arg configuration "$configuration" \
    '{runID:$run,notesForegroundEpoch:($notesForeground|tonumber),angryForegroundEpoch:($angryForeground|tonumber),callbackEpoch:($callback|tonumber),systemTimedAngrySeconds:($targetSeconds|tonumber),eventConfiguration:$configuration}' \
    > "$SESSION/result.json"
print "SpringBoard-timed Notes isolation and Angry threshold passed" > "$SESSION/AUTOMATION_PASS"
