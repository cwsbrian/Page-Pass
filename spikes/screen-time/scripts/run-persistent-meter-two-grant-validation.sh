#!/bin/zsh

set -eu
set -o pipefail
export PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"

if (( $# != 15 )); then
    print -u2 "usage: $0 DEVICE UDID GROUP BUNDLE LEASE1 TAKEOVER_LEASE TAKEOVER_NONCE NONCE1 LEASE2 NONCE2 SESSION CREDIT PRIMER_SECONDS NOTES_SECONDS MAX_TARGET_SECONDS"
    exit 64
fi

DEVICE=$1
UDID=$2
GROUP=$3
BUNDLE=$4
LEASE1=$5
TAKEOVER_LEASE=$6
TAKEOVER_NONCE=$7
NONCE1=$8
LEASE2=$9
NONCE2=${10}
SESSION=${11}
CREDIT=${12}
PRIMER_SECONDS=${13}
NOTES_SECONDS=${14}
MAX_TARGET_SECONDS=${15}
CAPACITY=$(( CREDIT * 2 ))
RESUME_PRIMER_SECONDS=${PAGEPASS_RESUME_AFTER_PRIMER_SECONDS:-}
RESUME_BEFORE_PRIMER=${PAGEPASS_RESUME_BEFORE_PRIMER:-}
TAKEOVER_ARGS=()
if [[ "$TAKEOVER_LEASE" != "-" && "$TAKEOVER_NONCE" != "-" ]]; then
    TAKEOVER_ARGS=(
        "--pagepass-automation-takeover-from=$TAKEOVER_LEASE"
        "--pagepass-automation-takeover-nonce=$TAKEOVER_NONCE"
    )
fi
CURRENT="$SESSION/current.plist"
SYSLOG="$SESSION/device-syslog.log"
CSV="$SESSION/samples.csv"
YEAR=$(date +%Y)

mkdir "$SESSION"
printf 'phase,sample,epoch,systemForegroundElapsed,credit,shielded,hits,run,event,lastThreshold\n' > "$CSV"

(( PRIMER_SECONDS > 0 && PRIMER_SECONDS < CREDIT )) || {
    print -u2 "PRIMER_SECONDS must be greater than zero and less than CREDIT"
    exit 64
}

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
    local lease=$1 nonce=$2
    [[ $(owner_field lease) == "$lease" ]] || fail "automation lease changed"
    [[ $(owner_field lastNonce) == "$nonce" ]] || fail "automation nonce changed"
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
    local bundle=$1 first_line=$2 destination=$3 line=""
    for _ in {1..60}; do
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
    local bundle=$1 first_line=$2 context=$3 destination=$4 line=""
    line=$(tail -n +$first_line "$SYSLOG" 2>/dev/null | awk -v bundle="$bundle" '
        (index($0, "Application process state changed for " bundle ":") && index($0, "visibility: Foreground")) ||
        (index($0, "app<" bundle) && index($0, "running-active-Visible")) { print; exit }
    ' || true)
    if [[ -n "$line" ]]; then
        print -r -- "$line" > "$destination"
        fail "$context was contaminated by an unexpected $bundle foreground transition"
    fi
}
append_sample() {
    local phase=$1 index=$2 foreground_epoch=$3 now json elapsed
    now=$(perl -MTime::HiRes=time -e 'printf "%.6f", time')
    elapsed=$(perl -e 'printf "%.3f", $ARGV[0]-$ARGV[1]' "$now" "$foreground_epoch")
    json=$(state_json)
    print "$phase,$index,$now,$elapsed,$(print -rn -- "$json" | jq -r '.creditSeconds,.isShielded,.thresholdReachedCount,(.activeRunID // "-"),(.activeEventName // "-"),.lastReachedCumulativeThresholdSeconds' | paste -sd, -)" >> "$CSV"
}
stop_syslog() {
    kill "$SYSLOG_PID" >/dev/null 2>&1 || true
    wait "$SYSLOG_PID" >/dev/null 2>&1 || true
}
wait_ready() {
    local lease=$1 nonce=$2 expected_hits=$3 expected_sequence=$4 expected_run=$5
    for _ in {1..40}; do
        sleep 1
        copy_state
        [[ $(owner_field lease 2>/dev/null || true) == "$lease" ]] || continue
        [[ $(owner_field lastNonce 2>/dev/null || true) == "$nonce" ]] || continue
        local json run
        json=$(state_json)
        run=$(print -rn -- "$json" | jq -r '.activeRunID // ""')
        [[ -z "$expected_run" || "$run" == "$expected_run" ]] || continue
        if [[ $(print -rn -- "$json" | jq -r '[.creditSeconds,.isShielded,.thresholdReachedCount,.intervalDidStart,.monitoringCompromised,.isPersistentMeter,.lastAppliedGrantSequence] | @tsv') == "$CREDIT"$'\tfalse\t'"$expected_hits"$'\ttrue\tfalse\ttrue\t'"$expected_sequence" ]]; then
            print -rn -- "$run"
            return
        fi
    done
    fail "persistent meter did not become ready for grant sequence $expected_sequence"
}
run_primer_and_force_quit() {
    local phase=$1 lease=$2 nonce=$3 run=$4 marker foreground launch_json pid i=0 now elapsed json termination_epoch primer_seconds
    launch_json="$SESSION/${phase}-primer-angry-launch.json"
    marker=$(( $(wc -l < "$SYSLOG") + 1 ))
    xcrun devicectl device process launch --device "$DEVICE" --terminate-existing \
        --json-output "$launch_json" com.rovio.baba >/dev/null
    foreground=$(wait_for_visibility com.rovio.baba "$marker" "$SESSION/${phase}-primer-angry-foreground.log")
    pid=$(jq -er '.result.process.processIdentifier' "$launch_json")

    while true; do
        now=$(perl -MTime::HiRes=time -e 'printf "%.6f", time')
        elapsed=$(perl -e 'printf "%.3f", $ARGV[0]-$ARGV[1]' "$now" "$foreground")
        jq -en --argjson elapsed "$elapsed" --argjson limit "$PRIMER_SECONDS" '$elapsed >= $limit' >/dev/null && break
        sleep 15
        copy_state
        require_owner "$lease" "$nonce"
        append_sample "$phase-primer-angry" "$i" "$foreground"
        json=$(state_json)
        [[ $(print -rn -- "$json" | jq -r '[.creditSeconds,.isShielded,.thresholdReachedCount,.activeRunID] | @tsv') == "$CREDIT"$'\tfalse\t0\t'"$run" ]] \
            || fail "$phase primer changed persistent credit before the threshold"
        i=$((i + 1))
    done

    marker=$(( $(wc -l < "$SYSLOG") + 1 ))
    termination_epoch=$(perl -MTime::HiRes=time -e 'printf "%.6f", time')
    xcrun devicectl device process terminate --device "$DEVICE" --pid "$pid" --kill \
        --json-output "$SESSION/${phase}-primer-angry-terminate.json" >/dev/null
    jq -e '.info.outcome == "success"' "$SESSION/${phase}-primer-angry-terminate.json" >/dev/null \
        || fail "$phase Angry Birds force termination failed"
    wait_for_process_exit com.rovio.baba "$marker" "$SESSION/${phase}-primer-angry-process-exit.log"

    primer_seconds=$(perl -e 'printf "%.3f", $ARGV[0]-$ARGV[1]' "$termination_epoch" "$foreground")
    copy_state
    append_sample "$phase-primer-terminated" "$i" "$foreground"
    json=$(state_json)
    [[ $(print -rn -- "$json" | jq -r '[.creditSeconds,.isShielded,.thresholdReachedCount,.activeRunID] | @tsv') == "$CREDIT"$'\tfalse\t0\t'"$run" ]] \
        || fail "$phase force termination changed persistent credit"
    print -rn -- "$primer_seconds"
}
run_notes_phase() {
    local phase=$1 lease=$2 nonce=$3 run=$4 marker foreground contamination_marker i=0 now elapsed json
    marker=$(( $(wc -l < "$SYSLOG") + 1 ))
    xcrun devicectl device process launch --device "$DEVICE" --terminate-existing \
        --json-output "$SESSION/${phase}-notes-launch.json" com.apple.mobilenotes >/dev/null
    foreground=$(wait_for_visibility com.apple.mobilenotes "$marker" "$SESSION/${phase}-notes-foreground.log")
    sleep 2
    contamination_marker=$(( $(wc -l < "$SYSLOG") + 1 ))
    while true; do
        now=$(perl -MTime::HiRes=time -e 'printf "%.6f", time')
        elapsed=$(perl -e 'printf "%.3f", $ARGV[0]-$ARGV[1]' "$now" "$foreground")
        jq -en --argjson elapsed "$elapsed" --argjson limit "$NOTES_SECONDS" '$elapsed >= $limit' >/dev/null && break
        sleep 30
        copy_state
        require_owner "$lease" "$nonce"
        assert_no_foreground_since com.rovio.baba "$contamination_marker" "$phase Notes phase" "$SESSION/${phase}-unexpected-angry-foreground.log"
        append_sample "$phase-notes" "$i" "$foreground"
        json=$(state_json)
        [[ $(print -rn -- "$json" | jq -r '[.creditSeconds,.isShielded,.activeRunID] | @tsv') == "$CREDIT"$'\tfalse\t'"$run" ]] \
            || fail "$phase Notes phase changed persistent credit"
        i=$((i + 1))
    done
    copy_state
    assert_no_foreground_since com.rovio.baba "$contamination_marker" "$phase Notes phase" "$SESSION/${phase}-unexpected-angry-foreground.log"
    append_sample "$phase-notes-final" "$i" "$foreground"
}
run_target_phase() {
    local phase=$1 lease=$2 nonce=$3 run=$4 expected_hits=$5 prior_usage=${6:-0} marker foreground contamination_marker i=0 json credit hits shielded callback target_seconds total_target_seconds
    marker=$(( $(wc -l < "$SYSLOG") + 1 ))
    xcrun devicectl device process launch --device "$DEVICE" --terminate-existing \
        --json-output "$SESSION/${phase}-angry-launch.json" com.rovio.baba >/dev/null
    foreground=$(wait_for_visibility com.rovio.baba "$marker" "$SESSION/${phase}-angry-foreground.log")
    sleep 2
    contamination_marker=$(( $(wc -l < "$SYSLOG") + 1 ))
    while true; do
        sleep 15
        copy_state
        require_owner "$lease" "$nonce"
        assert_no_foreground_since com.apple.mobilenotes "$contamination_marker" "$phase Angry phase" "$SESSION/${phase}-unexpected-notes-foreground.log"
        append_sample "$phase-angry" "$i" "$foreground"
        json=$(state_json)
        credit=$(print -rn -- "$json" | jq -er '.creditSeconds')
        hits=$(print -rn -- "$json" | jq -er '.thresholdReachedCount')
        shielded=$(print -rn -- "$json" | jq -r '.isShielded')
        if [[ "$credit" == 0 && "$hits" == "$expected_hits" && "$shielded" == true ]]; then
            callback=$(events_json | jq -er --arg run "$run" --argjson hits "$expected_hits" '[.[] | select(.name == "threshold reached" and .runID == $run and .creditAfter == 0) | (.timestamp + 978307200)] | .[$hits - 1]')
            target_seconds=$(perl -e 'printf "%.3f", $ARGV[0]-$ARGV[1]' "$callback" "$foreground")
            total_target_seconds=$(perl -e 'printf "%.3f", $ARGV[0]+$ARGV[1]' "$target_seconds" "$prior_usage")
            jq -en --argjson value "$total_target_seconds" --argjson floor "$CREDIT" --argjson ceiling "$MAX_TARGET_SECONDS" '$value >= $floor and $value <= $ceiling' >/dev/null \
                || fail "$phase total system-timed Angry usage was ${total_target_seconds}s (${prior_usage}s before force quit + ${target_seconds}s after relaunch); accepted ${CREDIT}...${MAX_TARGET_SECONDS}s"
            print -rn -- "$target_seconds"$'\t'"$total_target_seconds"
            return
        fi
        [[ "$credit" == "$CREDIT" && "$hits" == $(( expected_hits - 1 )) && "$shielded" == false ]] \
            || fail "$phase target phase entered an invalid state"
        i=$((i + 1))
    done
}

idevicesyslog -u "$UDID" --no-colors \
    -p 'SpringBoard|runningboardd|backboardd|FrontBoard' -o "$SYSLOG" &
SYSLOG_PID=$!
trap stop_syslog EXIT INT TERM
sleep 2

if [[ -n "$RESUME_PRIMER_SECONDS" || -n "$RESUME_BEFORE_PRIMER" ]]; then
    copy_state
    require_owner "$LEASE1" "$NONCE1"
    resume_json=$(state_json)
    [[ $(print -rn -- "$resume_json" | jq -r '[.creditSeconds,.isShielded,.thresholdReachedCount,.intervalDidStart,.monitoringCompromised,.isPersistentMeter,.lastAppliedGrantSequence] | @tsv') == "$CREDIT"$'\tfalse\t0\ttrue\tfalse\ttrue\t1' ]] \
        || fail "persistent meter was not resumable after the primer"
    RUN=$(print -rn -- "$resume_json" | jq -er '.activeRunID')
    INITIAL_ACTIVITY=$(print -rn -- "$resume_json" | jq -er '.activeActivityName')
    cp "$CURRENT" "$SESSION/initial-ready.plist"
    if [[ -n "$RESUME_BEFORE_PRIMER" ]]; then
        FIRST_PRIMER_SECONDS=$(run_primer_and_force_quit first "$LEASE1" "$NONCE1" "$RUN")
    else
        FIRST_PRIMER_SECONDS=$RESUME_PRIMER_SECONDS
    fi
else
    xcrun devicectl device process launch --device "$DEVICE" --terminate-existing com.apple.mobilenotes >/dev/null
    sleep 1
    xcrun devicectl device process launch --device "$DEVICE" --terminate-existing \
        --json-output "$SESSION/meter-start-launch.json" "$BUNDLE" \
        --pagepass-auto-persistent-meter-start \
        --pagepass-credit-seconds="$CREDIT" \
        --pagepass-quantum-seconds="$CREDIT" \
        --pagepass-meter-capacity-seconds="$CAPACITY" \
        --pagepass-grant-sequence=1 \
        --pagepass-automation-lease="$LEASE1" \
        --pagepass-automation-nonce="$NONCE1" \
        "${TAKEOVER_ARGS[@]}" >/dev/null

    RUN=$(wait_ready "$LEASE1" "$NONCE1" 0 1 "")
    INITIAL_ACTIVITY=$(state_json | jq -er '.activeActivityName')
    events=$(events_json)
    configuration=$(print -rn -- "$events" | jq -er --arg run "$RUN" '[.[] | select(.name == "monitoring start armed" and .runID == $run) | .detail] | last')
    [[ "$configuration" == *"cumulative thresholds=[$CREDIT, $CAPACITY]"* ]] || fail "persistent cumulative events were not pre-registered: $configuration"
    [[ "$configuration" == *"measurement grace=0s"* ]] || fail "persistent meter unexpectedly included measurement grace"
    cp "$CURRENT" "$SESSION/initial-ready.plist"

    FIRST_PRIMER_SECONDS=$(run_primer_and_force_quit first "$LEASE1" "$NONCE1" "$RUN")
fi
run_notes_phase first "$LEASE1" "$NONCE1" "$RUN"
FIRST_TIMING=$(run_target_phase first "$LEASE1" "$NONCE1" "$RUN" 1 "$FIRST_PRIMER_SECONDS")
FIRST_RESUMED_TARGET_SECONDS=$(print -rn -- "$FIRST_TIMING" | cut -f1)
FIRST_TOTAL_TARGET_SECONDS=$(print -rn -- "$FIRST_TIMING" | cut -f2)
copy_state
first_json=$(state_json)
[[ $(print -rn -- "$first_json" | jq -r '[.activeRunID,.activeActivityName,.activeEventName,.lastReachedCumulativeThresholdSeconds,.monitoringEnded] | @tsv') == "$RUN"$'\t'"$INITIAL_ACTIVITY"$'\tlimitedAppCredit-'"$RUN"'-'"$CAPACITY"$'\t'"$CREDIT"$'\tfalse' ]] \
    || fail "first depletion did not preserve persistent meter identity and next event"
cp "$CURRENT" "$SESSION/first-depleted.plist"

xcrun devicectl device process launch --device "$DEVICE" --terminate-existing \
    --json-output "$SESSION/second-grant-launch.json" "$BUNDLE" \
    --pagepass-auto-persistent-meter-grant \
    --pagepass-credit-seconds="$CREDIT" \
    --pagepass-quantum-seconds="$CREDIT" \
    --pagepass-meter-capacity-seconds="$CAPACITY" \
    --pagepass-grant-sequence=2 \
    --pagepass-automation-lease="$LEASE2" \
    --pagepass-automation-nonce="$NONCE2" \
    --pagepass-automation-takeover-from="$LEASE1" \
    --pagepass-automation-takeover-nonce="$NONCE1" >/dev/null

SECOND_RUN=$(wait_ready "$LEASE2" "$NONCE2" 1 2 "$RUN")
[[ "$SECOND_RUN" == "$RUN" ]] || fail "second grant changed persistent run ID"
[[ $(state_json | jq -er '.activeActivityName') == "$INITIAL_ACTIVITY" ]] || fail "second grant changed persistent activity name"
events_json | jq -e --arg run "$RUN" '[.[] | select(.name == "monitoring start armed" and .runID == $run)] | length == 1' >/dev/null \
    || fail "second grant called startMonitoring again"
cp "$CURRENT" "$SESSION/second-ready.plist"

run_notes_phase second "$LEASE2" "$NONCE2" "$RUN"
SECOND_TIMING=$(run_target_phase second "$LEASE2" "$NONCE2" "$RUN" 2)
SECOND_TARGET_SECONDS=$(print -rn -- "$SECOND_TIMING" | cut -f1)
copy_state
cp "$CURRENT" "$SESSION/final-state.plist"
events_json > "$SESSION/events.json"
jq -n --arg run "$RUN" --arg activity "$INITIAL_ACTIVITY" \
    --arg primer "$FIRST_PRIMER_SECONDS" --arg resumed "$FIRST_RESUMED_TARGET_SECONDS" \
    --arg firstTotal "$FIRST_TOTAL_TARGET_SECONDS" --arg second "$SECOND_TARGET_SECONDS" \
    '{runID:$run,activityName:$activity,firstGrantPrimerAngrySeconds:($primer|tonumber),firstGrantResumedAngrySeconds:($resumed|tonumber),firstGrantTotalAngrySeconds:($firstTotal|tonumber),secondGrantAngrySeconds:($second|tonumber),monitorRestartCount:1}' \
    > "$SESSION/result.json"
print "Two grants consumed on one persistent cumulative monitor" > "$SESSION/AUTOMATION_PASS"
