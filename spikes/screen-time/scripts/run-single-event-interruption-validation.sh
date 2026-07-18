#!/bin/zsh

set -eu
set -o pipefail
export PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"

if (( $# < 12 || $# > 13 )); then
    print -u2 "usage: $0 DEVICE GROUP BUNDLE LEASE TAKEOVER_LEASE TAKEOVER_NONCE NONCE SESSION CREDIT FIRST_ANGRY NOTES GRACE [foreground|background|none|manual]"
    exit 64
fi

DEVICE=$1
GROUP=$2
BUNDLE=$3
LEASE=$4
TAKEOVER_LEASE=$5
TAKEOVER_NONCE=$6
NONCE=$7
SESSION=$8
CREDIT=${9}
FIRST_ANGRY=${10}
NOTES=${11}
GRACE=${12}
TERMINATION_MODE=${13:-foreground}
PHYSICAL=$((CREDIT + GRACE))
(( GRACE == 0 )) || { print -u2 "single-event interruption probe requires GRACE=0"; exit 64; }
[[ "$TERMINATION_MODE" == foreground || "$TERMINATION_MODE" == background || "$TERMINATION_MODE" == none || "$TERMINATION_MODE" == manual ]] \
    || { print -u2 "termination mode must be foreground, background, none, or manual"; exit 64; }
VISIBILITY_POLLS=60
[[ "$TERMINATION_MODE" == manual ]] && VISIBILITY_POLLS=600
CURRENT="$SESSION/current.plist"
CSV="$SESSION/samples.csv"
mkdir "$SESSION"
printf 'phase,sample,epoch,elapsed,credit,shielded,hits,run,event\n' > "$CSV"
SYSLOG="$SESSION/device-syslog.log"
YEAR=$(date +%Y)
idevicesyslog -u 00008020-00192D321A21002E > "$SYSLOG" 2>&1 &
SYSLOG_PID=$!
trap 'kill "$SYSLOG_PID" >/dev/null 2>&1 || true; wait "$SYSLOG_PID" >/dev/null 2>&1 || true' EXIT

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
sample() {
    local phase=$1 index=$2 start=$3 now json elapsed
    now=$(perl -MTime::HiRes=time -e 'printf "%.6f", time')
    json=$(state_json)
    elapsed=$(perl -e 'printf "%.3f", $ARGV[0]-$ARGV[1]' "$now" "$start")
    print "$phase,$index,$now,$elapsed,$(print -rn -- "$json" | jq -r '.creditSeconds,.isShielded,.thresholdReachedCount,(.activeRunID // "-"),(.activeEventName // "-")' | paste -sd, -)" >> "$CSV"
}
wait_for_not_visible() {
    local bundle=$1 first_line=$2 destination=$3 line="" attempt
    for (( attempt=1; attempt<=VISIBILITY_POLLS; attempt++ )); do
        line=$(tail -n +$first_line "$SYSLOG" 2>/dev/null | awk -v bundle="$bundle" '
            index($0, "app<" bundle) &&
            !index($0, "xpcservice<") && index($0, "NotVisible") { print; exit }
        ' || true)
        if [[ -n "$line" ]]; then
            print -r -- "$line" > "$destination"
            system_epoch "$line"
            return
        fi
        sleep 0.5
    done
    fail "$bundle did not reach a system NotVisible state"
}
system_epoch() {
    local line=$1
    SYSTEM_LOG_LINE="$line" YEAR="$YEAR" perl -MTime::Local -e '
        my %month = (Jan=>0,Feb=>1,Mar=>2,Apr=>3,May=>4,Jun=>5,Jul=>6,Aug=>7,Sep=>8,Oct=>9,Nov=>10,Dec=>11);
        my $line = $ENV{SYSTEM_LOG_LINE};
        $line =~ /^(\w{3})\s+(\d+)\s+(\d+):(\d+):(\d+)\.(\d+)/ or die "bad syslog timestamp";
        my $fraction = "0.$6";
        printf "%.6f", timelocal($5,$4,$3,$2,$month{$1},$ENV{YEAR}-1900) + $fraction;
    '
}
wait_for_visibility() {
    local bundle=$1 first_line=$2 destination=$3 line="" attempt
    for (( attempt=1; attempt<=VISIBILITY_POLLS; attempt++ )); do
        line=$(tail -n +$first_line "$SYSLOG" 2>/dev/null | awk -v bundle="$bundle" '
            (index($0, "Application process state changed for " bundle ":") && index($0, "visibility: Foreground")) ||
            (index($0, "app<" bundle) && index($0, "running-active-Visible")) { print; exit }
        ' || true)
        if [[ -n "$line" ]]; then
            print -r -- "$line" > "$destination"
            system_epoch "$line"
            return
        fi
        sleep 0.5
    done
    fail "$bundle did not reach system foreground visibility"
}
wait_for_process_exit() {
    local bundle=$1 first_line=$2 destination=$3 line=""
    for _ in {1..60}; do
        line=$(tail -n +$first_line "$SYSLOG" 2>/dev/null | awk -v bundle="$bundle" '
            index($0, "Application process state changed for " bundle ": (null)") { print; exit }
        ' || true)
        if [[ -n "$line" ]]; then
            print -r -- "$line" > "$destination"
            return
        fi
        sleep 0.5
    done
    fail "$bundle process exit was not confirmed by SpringBoard"
}
assert_no_foreground_since() {
    local bundle=$1 first_line=$2 destination=$3 line=""
    line=$(tail -n +$first_line "$SYSLOG" 2>/dev/null | awk -v bundle="$bundle" '
        (index($0, "Application process state changed for " bundle ":") && index($0, "visibility: Foreground")) ||
        (index($0, "app<" bundle) && index($0, "running-active-Visible")) { print; exit }
    ' || true)
    if [[ -n "$line" ]]; then
        print -r -- "$line" > "$destination"
        fail "Notes phase contained an unexpected Angry Birds foreground transition"
    fi
}

xcrun devicectl device process launch --device "$DEVICE" --terminate-existing \
    --json-output "$SESSION/baseline-notes.json" com.apple.mobilenotes >/dev/null
sleep 1
AUTOMATION_ARGUMENTS=(
    --pagepass-auto-legacy-proof
    --pagepass-no-measurement-grace
    --pagepass-credit-seconds="$CREDIT"
    --pagepass-automation-lease="$LEASE"
    --pagepass-automation-nonce="$NONCE"
)
if [[ "$TAKEOVER_LEASE" != "-" && "$TAKEOVER_NONCE" != "-" ]]; then
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
[[ -n "$RUN" ]] || fail "single-event run did not become ready"
cp "$CURRENT" "$SESSION/initial-ready.plist"

ANGRY1_MARKER=$(( $(wc -l < "$SYSLOG") + 1 ))
if [[ "$TERMINATION_MODE" == manual ]]; then
    print "ACTION: On the iPhone, tap the Angry Birds 2 icon now. Do not use the Mac to open it."
else
    xcrun devicectl device process launch --device "$DEVICE" --terminate-existing \
        --json-output "$SESSION/angry1-launch.json" com.rovio.baba >/dev/null
fi
ANGRY1_START=$(wait_for_visibility com.rovio.baba "$ANGRY1_MARKER" "$SESSION/angry1-foreground.log")
if [[ "$TERMINATION_MODE" == manual ]]; then
    ANGRY_PID=$(perl -ne 'if (/state update for (\d+)/) { print $1; exit }' "$SESSION/angry1-foreground.log")
    [[ -n "$ANGRY_PID" ]] || fail "could not parse manually launched Angry Birds PID"
else
    ANGRY_PID=$(jq -er '.result.process.processIdentifier' "$SESSION/angry1-launch.json")
fi
i=0
while true; do
    now=$(perl -MTime::HiRes=time -e 'printf "%.6f", time')
    elapsed=$(perl -e 'printf "%.3f", $ARGV[0]-$ARGV[1]' "$now" "$ANGRY1_START")
    jq -en --argjson elapsed "$elapsed" --argjson limit "$FIRST_ANGRY" '$elapsed >= $limit' >/dev/null && break
    sleep 5
    copy_state
    require_owner
    sample angry1 "$i" "$ANGRY1_START"
    json=$(state_json)
    [[ $(print -rn -- "$json" | jq -r '[.creditSeconds,.isShielded,.thresholdReachedCount,.activeRunID] | @tsv') == "$CREDIT"$'\tfalse\t0\t'"$RUN" ]] \
        || fail "single event fired during the first partial use"
    i=$((i + 1))
done

if [[ "$TERMINATION_MODE" == background || "$TERMINATION_MODE" == none || "$TERMINATION_MODE" == manual ]]; then
    NOTES_MARKER=$(( $(wc -l < "$SYSLOG") + 1 ))
    if [[ "$TERMINATION_MODE" == manual ]]; then
        print "ACTION: On the iPhone, tap the Notes icon now. Leave Angry Birds in the app switcher."
    else
        xcrun devicectl device process launch --device "$DEVICE" --terminate-existing \
            --json-output "$SESSION/notes-launch.json" com.apple.mobilenotes >/dev/null
    fi
    NOTES_START=$(wait_for_visibility com.apple.mobilenotes "$NOTES_MARKER" "$SESSION/notes-foreground.log")
    ANGRY1_END=$(wait_for_not_visible com.rovio.baba "$NOTES_MARKER" "$SESSION/angry1-not-visible.log")
    if [[ "$TERMINATION_MODE" == background ]]; then
        sleep 2
        EXIT_MARKER=$(( $(wc -l < "$SYSLOG") + 1 ))
        xcrun devicectl device process terminate --device "$DEVICE" --pid "$ANGRY_PID" --kill \
            --json-output "$SESSION/angry1-terminate.json" >/dev/null
        jq -e '.info.outcome == "success"' "$SESSION/angry1-terminate.json" >/dev/null \
            || fail "background Angry Birds termination failed"
        wait_for_process_exit com.rovio.baba "$EXIT_MARKER" "$SESSION/angry1-process-exit.log"
    fi
else
    ANGRY1_END=$(perl -MTime::HiRes=time -e 'printf "%.6f", time')
    EXIT_MARKER=$(( $(wc -l < "$SYSLOG") + 1 ))
    xcrun devicectl device process terminate --device "$DEVICE" --pid "$ANGRY_PID" --kill \
        --json-output "$SESSION/angry1-terminate.json" >/dev/null
    jq -e '.info.outcome == "success"' "$SESSION/angry1-terminate.json" >/dev/null \
        || fail "foreground Angry Birds force termination failed"
    wait_for_process_exit com.rovio.baba "$EXIT_MARKER" "$SESSION/angry1-process-exit.log"

    NOTES_MARKER=$(( $(wc -l < "$SYSLOG") + 1 ))
    xcrun devicectl device process launch --device "$DEVICE" --terminate-existing \
        --json-output "$SESSION/notes-launch.json" com.apple.mobilenotes >/dev/null
    NOTES_START=$(wait_for_visibility com.apple.mobilenotes "$NOTES_MARKER" "$SESSION/notes-foreground.log")
fi
sleep 2
NOTES_CONTAMINATION_MARKER=$(( $(wc -l < "$SYSLOG") + 1 ))
i=0
while true; do
    now=$(perl -MTime::HiRes=time -e 'printf "%.6f", time')
    elapsed=$(perl -e 'printf "%.3f", $ARGV[0]-$ARGV[1]' "$now" "$NOTES_START")
    jq -en --argjson elapsed "$elapsed" --argjson limit "$NOTES" '$elapsed >= $limit' >/dev/null && break
    sleep 5
    copy_state
    require_owner
    assert_no_foreground_since com.rovio.baba "$NOTES_CONTAMINATION_MARKER" "$SESSION/unexpected-angry-foreground.log"
    sample notes "$i" "$NOTES_START"
    json=$(state_json)
    [[ $(print -rn -- "$json" | jq -r '[.creditSeconds,.isShielded,.thresholdReachedCount,.activeRunID] | @tsv') == "$CREDIT"$'\tfalse\t0\t'"$RUN" ]] \
        || fail "Notes changed the single-event run"
    i=$((i + 1))
done
assert_no_foreground_since com.rovio.baba "$NOTES_CONTAMINATION_MARKER" "$SESSION/unexpected-angry-foreground.log"
cp "$CURRENT" "$SESSION/notes-complete.plist"

ANGRY1_WALL=$(perl -e 'printf "%.3f", $ARGV[0]-$ARGV[1]' "$ANGRY1_END" "$ANGRY1_START")
EARLIEST=$(perl -e '$v=$ARGV[0]-$ARGV[1]-5; printf "%.3f", $v > 0 ? $v : 0' "$PHYSICAL" "$ANGRY1_WALL")
ANGRY2_MARKER=$(( $(wc -l < "$SYSLOG") + 1 ))
if [[ "$TERMINATION_MODE" == manual ]]; then
    print "ACTION: On the iPhone, tap the Angry Birds 2 icon now. Do not use the app switcher or the Mac."
elif [[ "$TERMINATION_MODE" == none ]]; then
    xcrun devicectl device process launch --device "$DEVICE" \
        --json-output "$SESSION/angry2-launch.json" com.rovio.baba >/dev/null
else
    xcrun devicectl device process launch --device "$DEVICE" --terminate-existing \
        --json-output "$SESSION/angry2-launch.json" com.rovio.baba >/dev/null
fi
ANGRY2_START=$(wait_for_visibility com.rovio.baba "$ANGRY2_MARKER" "$SESSION/angry2-foreground.log")
i=0
while true; do
    sleep 1
    copy_state
    require_owner
    sample angry2 "$i" "$ANGRY2_START"
    json=$(state_json)
    credit=$(print -rn -- "$json" | jq -er '.creditSeconds')
    hits=$(print -rn -- "$json" | jq -er '.thresholdReachedCount')
    shielded=$(print -rn -- "$json" | jq -r '.isShielded')
    now=$(perl -MTime::HiRes=time -e 'printf "%.6f", time')
    elapsed=$(perl -e 'printf "%.3f", $ARGV[0]-$ARGV[1]' "$now" "$ANGRY2_START")
    if [[ "$credit" == 0 && "$hits" == 1 && "$shielded" == true ]]; then
        jq -en --argjson elapsed "$elapsed" --argjson earliest "$EARLIEST" '$elapsed >= $earliest' >/dev/null \
            || fail "single final callback was early at ${elapsed}s; floor=${EARLIEST}s"
        break
    fi
    [[ "$credit" == "$CREDIT" && "$hits" == 0 && "$shielded" == false ]] \
        || fail "single-event run entered an invalid intermediate state"
    jq -en --argjson elapsed "$elapsed" --argjson limit "$((PHYSICAL + 160))" '$elapsed < $limit' >/dev/null \
        || fail "single final callback timed out"
    i=$((i + 1))
done

cp "$CURRENT" "$SESSION/final-state.plist"
events_json > "$SESSION/events.json"
jq -n --arg run "$RUN" --argjson credit "$CREDIT" --argjson grace "$GRACE" \
    --arg mode "$TERMINATION_MODE" --argjson first "$ANGRY1_WALL" --argjson notes "$NOTES" --argjson second "$elapsed" \
    --argjson pid "$ANGRY_PID" \
    '{runID:$run,creditSeconds:$credit,graceSeconds:$grace,terminationMode:$mode,targetPID:$pid,firstAngryWallSeconds:$first,notesSeconds:$notes,secondAngryWallSeconds:$second}' \
    > "$SESSION/result.json"
print "single final event ignored Notes and enforced zero credit" > "$SESSION/AUTOMATION_PASS"
