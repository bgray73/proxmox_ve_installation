#!/bin/bash
# Independent root policy; NUT upsmon retains its native critical/FSD path.
set -euo pipefail
CONFIG=/etc/nut/policy.conf
DRY_RUN=0
case "${1:-}" in
    --dry-run) DRY_RUN=1 ;;
    "") ;;
    *) echo "Usage: $0 [--dry-run]" >&2; exit 2 ;;
esac
[[ -r "$CONFIG" ]] || { echo "Missing $CONFIG" >&2; exit 1; }
# This file must be owned by root and not writable by other users.
# shellcheck source=/dev/null
source "$CONFIG"
for n in DELAY COMM_DELAY POLL STAGGER; do
    [[ ${!n} =~ ^[0-9]+$ ]] || { echo "Invalid $n" >&2; exit 1; }
done
(( POLL > 0 )) || exit 1
[[ "$UPS_A $UPS_B" != *'<'* ]] || { echo "Replace UPS address placeholders" >&2; exit 1; }
token() { [[ " $1 " == *" $2 "* ]]; }
status() {
    local value
    value=$(timeout 4 upsc "$1" ups.status 2>/dev/null) || value=UNKNOWN
    printf '%s' "$value"
}
log() { logger -t nut-policy -- "$*"; printf '%s\n' "$*"; }
outage_start=-1
unknown_start=-1
while true; do
    a=$(status "$UPS_A")
    b=$(status "$UPS_B")
    now=$SECONDS
    reason=""
    # Critical feeds are OB+LB, FSD, OFF; an OL feed remains usable.
    if token "$a" FSD && token "$b" FSD; then
        reason="both UPS feeds have FSD"
    elif token "$a" OB && token "$b" OB; then
        unknown_start=-1
        (( outage_start >= 0 )) || outage_start=$now
        if token "$a" LB || token "$b" LB; then
            reason="both feeds on battery and at least one low battery"
        elif (( now - outage_start >= DELAY + STAGGER )); then
            reason="both feeds on battery beyond outage grace"
        fi
    elif token "$a" OL || token "$b" OL; then
        outage_start=-1
        unknown_start=-1
    else
        # No confirmed mains feed, including missing/stale data, OFF, or
        # one failed feed plus one on battery. Use a bounded fail-safe window.
        outage_start=-1
        (( unknown_start >= 0 )) || unknown_start=$now
        if (( now - unknown_start >= COMM_DELAY )); then
            reason="no confirmed mains feed; communication/degraded grace expired"
        fi
    fi
    if (( DRY_RUN )); then
        printf 'UPS A=%s | UPS B=%s | reason=%s | dry-run: no shutdown\n' "$a" "$b" "${reason:-none}"
        exit 0
    fi
    if [[ -n "$reason" ]]; then
        log "$reason; requesting native host shutdown"
        /sbin/shutdown -h now "NUT: $reason"
        exit 0
    fi
    sleep "$POLL"
done
