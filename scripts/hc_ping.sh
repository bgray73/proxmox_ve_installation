#!/usr/bin/env bash
# Healthchecks.io dead-man's switch reporter for the homelab.
#
# Two checks, both pinged from ONE PVE node:
#   heartbeat : every 5 min — verifies Corosync quorum is healthy, then pings
#               success. On quorum failure pings the check's /fail endpoint.
#   backups   : daily after the backup window — verifies every guest's latest
#               PBS backup is fresher than --max-age-hours (default 30).
#
# If the whole site goes dark, pings stop and Healthchecks.io pages the
# operator. The watcher and the alert path both live offsite on purpose:
# the on-site ntfy cannot alert when the site itself is down.
set -euo pipefail

# Cron's PATH is minimal; pvecm lives in /usr/sbin.
export PATH="/usr/sbin:/sbin:${PATH}"

fail() { echo "ERROR: $*" >&2; exit 1; }
log() { echo "$*"; }

usage() {
  cat <<'EOF'
Usage:
  hc_ping.sh --check heartbeat|backups [options]

Options:
  --check heartbeat|backups  required: which Healthchecks.io check to report
  --pbs-storage ID           PBS storage for the backups check (auto-detected
                             when exactly one active PBS storage exists; or env
                             PBS_STORAGE)
  --max-age-hours N          backups check: fail if any guest's latest backup
                             is older (default: 30; or env HC_MAX_AGE_HOURS)
  -h, --help                 show this help

Environment (keep in /root/.hc.env, mode 600, root-only):
  HC_HEARTBEAT_URL   ping URL of the lab-heartbeat check, e.g.
                     https://hc-ping.com/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee
  HC_BACKUPS_URL     ping URL of the nightly-backups check

Suggested cron — run on ONE PVE node only (e.g. pve01), /etc/cron.d/hc-lab:
  */5 * * * * root . /root/.hc.env; /usr/local/bin/hc_ping.sh --check heartbeat
  0 6 * * *   root . /root/.hc.env; /usr/local/bin/hc_ping.sh --check backups

See docs/DEADMAN-SWITCH.md for the full runbook.
EOF
}

CHECK=""
PBS_STORAGE="${PBS_STORAGE:-}"
MAX_AGE_HOURS="${HC_MAX_AGE_HOURS:-30}"
HC_HEARTBEAT_URL="${HC_HEARTBEAT_URL:-}"
HC_BACKUPS_URL="${HC_BACKUPS_URL:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check) CHECK="${2:?}"; shift 2 ;;
    --pbs-storage) PBS_STORAGE="${2:?}"; shift 2 ;;
    --max-age-hours) MAX_AGE_HOURS="${2:?}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) fail "unknown argument: $1 (see --help)" ;;
  esac
done

[[ "$CHECK" == "heartbeat" || "$CHECK" == "backups" ]] || fail "--check must be heartbeat or backups"
command -v curl >/dev/null || fail "curl is required"

# hc_ping <url> [message]: success ping; with a message, POST it to a /fail URL
# so the reason lands in the check's ping log. Returns curl's exit status.
hc_ping() {
  local url="$1" msg="${2:-}"
  if [[ -n "$msg" ]]; then
    curl --fail -sS --retry 2 -m 20 -d "$msg" "$url" >/dev/null
  else
    curl --fail -sS --retry 2 -m 20 "$url" >/dev/null
  fi
}

# Prints the reason quorum is unhealthy (stdout) and returns 1; silent 0 when
# healthy: quorate, total votes == expected votes, all members present.
quorum_healthy() {
  command -v pvecm >/dev/null || { echo "pvecm not found (not a PVE node?)"; return 1; }
  local out
  out="$(pvecm status 2>&1)" || { echo "pvecm status failed"; return 1; }
  local quorate expected total members
  quorate="$(printf '%s\n' "$out" | awk -F: '/^Quorate:/{gsub(/[[:space:]]/,"",$2); print $2; exit}' || true)"
  expected="$(printf '%s\n' "$out" | awk -F: '/^Expected votes:/{gsub(/[[:space:]]/,"",$2); print $2; exit}' || true)"
  total="$(printf '%s\n' "$out" | awk -F: '/^Total votes:/{gsub(/[[:space:]]/,"",$2); print $2; exit}' || true)"
  members="$(printf '%s\n' "$out" | grep -c '^0x[0-9a-fA-F]' || true)"
  [[ "$quorate" == "Yes" ]] || { echo "not quorate (Quorate='${quorate:-unknown}')"; return 1; }
  [[ -n "$expected" && -n "$total" ]] || { echo "could not parse vote counts"; return 1; }
  [[ "$total" -eq "$expected" ]] || { echo "votes ${total}/${expected}"; return 1; }
  [[ "$members" -eq "$expected" ]] || { echo "members ${members}/${expected}"; return 1; }
}

# Pick the PBS storage: explicit flag wins, otherwise auto-detect when unambiguous.
resolve_pbs_storage() {
  if [[ -n "$PBS_STORAGE" ]]; then return 0; fi
  command -v pvesm >/dev/null || fail "pvesm not found (not a PVE node?)"
  local found
  found="$(pvesm status 2>/dev/null | awk 'NR>1 && $2=="pbs" && $3=="active" {print $1}')"
  local count
  count="$(printf '%s' "$found" | grep -c . || true)"
  if [[ "$count" -eq 1 ]]; then
    PBS_STORAGE="$found"
    log "Auto-detected PBS storage: $PBS_STORAGE"
  elif [[ "$count" -eq 0 ]]; then
    fail "no active PBS storage found; pass --pbs-storage ID"
  else
    fail "multiple PBS storages found; pass --pbs-storage ID"
  fi
}

# Print "vmid|type|epoch" for the latest backup of every backed-up guest
# (same proven parsing as scripts/pbs_restore_test.sh).
all_latest_backups() {
  pvesh get "/nodes/localhost/storage/${PBS_STORAGE}/content" \
    --content backup --output-format json 2>/dev/null \
  | python3 -c '
import json, re, sys
from datetime import datetime, timezone
best = {}
for item in json.load(sys.stdin):
    volid = item.get("volid", "")
    m = re.search(r"vzdump-(qemu|lxc)-(\d+)-(\d{4})_(\d{2})_(\d{2})-(\d{2})_(\d{2})_(\d{2})", volid)
    if not m:
        continue
    ts = datetime(int(m.group(3)), int(m.group(4)), int(m.group(5)),
                  int(m.group(6)), int(m.group(7)), int(m.group(8)),
                  tzinfo=timezone.utc)
    epoch = int(ts.timestamp())
    key = m.group(2)
    if key not in best or epoch > best[key][2]:
        best[key] = (key, m.group(1), epoch)
for key in sorted(best, key=int):
    print("%s|%s|%s" % best[key])
'
}

do_heartbeat() {
  [[ -n "$HC_HEARTBEAT_URL" ]] || fail "HC_HEARTBEAT_URL is not set; create the lab-heartbeat check at healthchecks.io and store its ping URL in /root/.hc.env (see --help)"
  local reason
  if reason="$(quorum_healthy)"; then
    hc_ping "$HC_HEARTBEAT_URL" || fail "could not reach Healthchecks.io (${HC_HEARTBEAT_URL})"
    log "heartbeat OK: quorum healthy, pinged Healthchecks.io"
  else
    hc_ping "${HC_HEARTBEAT_URL}/fail" "quorum unhealthy: ${reason}" \
      || log "WARNING: could not reach Healthchecks.io fail endpoint"
    fail "quorum unhealthy: ${reason}"
  fi
}

do_backups() {
  [[ -n "$HC_BACKUPS_URL" ]] || fail "HC_BACKUPS_URL is not set; create the nightly-backups check at healthchecks.io and store its ping URL in /root/.hc.env (see --help)"
  command -v pvesh >/dev/null || fail "pvesh not found (not a PVE node?)"
  command -v python3 >/dev/null || fail "python3 is required for JSON parsing"
  resolve_pbs_storage
  local now cutoff rows
  now="$(date +%s)"
  cutoff=$(( MAX_AGE_HOURS * 3600 ))
  rows="$(all_latest_backups)"
  if [[ -z "$rows" ]]; then
    local msg="no backups found on storage ${PBS_STORAGE}"
    hc_ping "${HC_BACKUPS_URL}/fail" "$msg" \
      || log "WARNING: could not reach Healthchecks.io fail endpoint"
    fail "$msg"
  fi
  local problems=()
  while IFS='|' read -r vmid _gtype epoch; do
    [[ -n "$vmid" ]] || continue
    local age_h=$(( (now - epoch) / 3600 ))
    if (( now - epoch > cutoff )); then
      problems+=("${vmid} (${age_h}h old)")
    fi
  done <<< "$rows"
  if (( ${#problems[@]} > 0 )); then
    local msg="stale backups on ${PBS_STORAGE}: ${problems[*]}"
    hc_ping "${HC_BACKUPS_URL}/fail" "$msg" \
      || log "WARNING: could not reach Healthchecks.io fail endpoint"
    fail "$msg"
  fi
  hc_ping "$HC_BACKUPS_URL" || fail "could not reach Healthchecks.io (${HC_BACKUPS_URL})"
  local count
  count="$(printf '%s\n' "$rows" | grep -c . || true)"
  log "backups OK: ${count} guest(s), all within ${MAX_AGE_HOURS}h, pinged Healthchecks.io"
}

case "$CHECK" in
  heartbeat) do_heartbeat ;;
  backups) do_backups ;;
esac
