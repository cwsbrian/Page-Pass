#!/bin/zsh

set -eu
set -o pipefail
export PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"

if (( $# != 12 )); then
    print -u2 "usage: $0 DEVICE GROUP RUN LEASE PHASE START_EPOCH DURATION_SECONDS INTERVAL_SECONDS CSV STATE_PLIST DONE_MARKER FAIL_MARKER"
    exit 64
fi

DEVICE=$1
GROUP=$2
EXPECTED_RUN=$3
EXPECTED_LEASE=$4
PHASE=$5
START_EPOCH=$6
DURATION_SECONDS=$7
INTERVAL_SECONDS=$8
CSV=$9
STATE_PLIST=${10}
DONE_MARKER=${11}
FAIL_MARKER=${12}

rm -f "$DONE_MARKER" "$FAIL_MARKER"
if [[ ! -f "$CSV" ]]; then
    print "csv missing before sampling" > "$FAIL_MARKER"
    exit 7
fi
SAMPLE=$(awk -F, -v phase="$PHASE" '$1 == phase { count += 1 } END { print count + 0 }' "$CSV")

while true; do
    NOW=$(date +%s)
    ELAPSED=$((NOW - START_EPOCH))
    rm -f "$STATE_PLIST"

    if ! xcrun devicectl device copy from \
        --device "$DEVICE" \
        --domain-type appGroupDataContainer \
        --domain-identifier "$GROUP" \
        --source "Library/Preferences/$GROUP.plist" \
        --destination "$STATE_PLIST" >/dev/null 2>&1; then
        print "copy failed at $ELAPSED" > "$FAIL_MARKER"
        exit 5
    fi

    if ! JSON=$(plutil -extract state raw -o - "$STATE_PLIST" | base64 -D); then
        print "state payload missing or invalid at $ELAPSED" > "$FAIL_MARKER"
        exit 8
    fi
    if ! VALUES=$(print -rn -- "$JSON" | jq -er '
        if (.creditSeconds | type) == "number"
            and (.isShielded | type) == "boolean"
            and (.thresholdReachedCount | type) == "number"
            and (.activeRunID | type) == "string"
        then [.creditSeconds, .isShielded, .thresholdReachedCount, .activeRunID] | @tsv
        else error("required state field missing or invalid")
        end
    '); then
        print "state fields missing or invalid at $ELAPSED" > "$FAIL_MARKER"
        exit 9
    fi
    IFS=$'\t' read -r CREDIT SHIELDED HITS CURRENT_RUN <<< "$VALUES"
    if OWNERSHIP=$(plutil -extract automationOwnership raw -o - "$STATE_PLIST" 2>/dev/null | base64 -D) &&
       CURRENT_LEASE=$(print -rn -- "$OWNERSHIP" | jq -er '.lease | select(type == "string" and length > 0)'); then
        :
    elif ! CURRENT_LEASE=$(plutil -extract automationLease raw -o - "$STATE_PLIST"); then
        print "automation lease missing at $ELAPSED" > "$FAIL_MARKER"
        exit 10
    fi

    print "$PHASE,$SAMPLE,$NOW,$ELAPSED,$CREDIT,$SHIELDED,$HITS,$CURRENT_RUN,$CURRENT_LEASE" >> "$CSV"

    if [[ "$CURRENT_RUN" != "$EXPECTED_RUN" ]]; then
        print "run changed to $CURRENT_RUN at $ELAPSED" > "$FAIL_MARKER"
        exit 4
    fi
    if [[ "$CURRENT_LEASE" != "$EXPECTED_LEASE" ]]; then
        print "lease changed to $CURRENT_LEASE at $ELAPSED" > "$FAIL_MARKER"
        exit 6
    fi
    if (( ELAPSED >= DURATION_SECONDS )); then
        print "completed at $ELAPSED" > "$DONE_MARKER"
        exit 0
    fi

    SAMPLE=$((SAMPLE + 1))
    sleep "$INTERVAL_SECONDS"
done
