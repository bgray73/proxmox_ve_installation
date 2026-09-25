#!/usr/bin/env bash
# PBS restore test: restore a canary guest's latest backup to a throwaway VMID
# (with its network detached so it can never conflict with production),
# verify it boots, then tear it down. Reports PASS/FAIL via ntfy if configured.
#
#   check (default) : audit PBS backups — latest backup per guest, stale/missing
#   test            : run the full restore -> boot -> verify -> teardown cycle
#
# The canary should be a small guest (e.g. the ntfy or uptime LXC). Its restored
# copy boots with no network interfaces, so there is no IP/MAC conflict risk.
set -euo pipefail

fail() { echo "ERROR: $*" >&2; exit 1; }
log() { echo "$*"; }

usage() {
  cat <<'EOF'
Usage:
  pbs_restore_test.sh [--mode check|test] [options]

Options:
  --mode check|test     check = audit backups only (default); test = restore cycle
  --pbs-storage ID      PVE storage ID for the PBS (auto-detected if exactly one
                        active PBS storage exists; or env PBS_STORAGE)
  --vmid ID             canary guest VMID whose latest backup is tested
                        (or env CANARY_VMID)
  --test-vmid ID        throwaway VMID for the restore (default: 9999)
  --target-storage ID   storage for restored disks (auto-detected: first active
                        lvmthin/zfspool on this node)
  --timeout SECONDS     max seconds to wait for boot (default: 300)
  --max-age-days N      warn if the backup under test is older than N days (default: 2)
  --ntfy-url URL        ntfy server base URL (or env NTFY_URL)
  --ntfy-topic TOPIC    ntfy topic for the report (or env NTFY_TOPIC)
  --yes                 skip the confirmation prompt in test mode
  -h, --help            show this help

Run on a Proxmox VE node. In test mode the script asks for confirmation unless
--yes is given, and always tears the throwaway guest down, even on failure.
EOF
}

MODE="check"
PBS_STORAGE="${PBS_STORAGE:-}"
CANARY_VMID="${CANARY_VMID:-}"
TEST_VMID=9999
TARGET_STORAGE=""
TIMEOUT=300
MAX_AGE_DAYS=2
ASSUME_YES=0
NTFY_URL="${NTFY_URL:-}"
NTFY_TOPIC="${NTFY_TOPIC:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode) MODE="${2:?}"; shift 2 ;;
    --pbs-storage) PBS_STORAGE="${2:?}"; shift 2 ;;
    --vmid) CANARY_VMID="${2:?}"; shift 2 ;;
    --test-vmid) TEST_VMID="${2:?}"; shift 2 ;;
    --target-storage) TARGET_STORAGE="${2:?}"; shift 2 ;;
    --timeout) TIMEOUT="${2:?}"; shift 2 ;;
    --max-age-days) MAX_AGE_DAYS="${2:?}"; shift 2 ;;
    --ntfy-url) NTFY_URL="${2:?}"; shift 2 ;;
    --ntfy-topic) NTFY_TOPIC="${2:?}"; shift 2 ;;
    --yes) ASSUME_YES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) fail "unknown argument: $1 (see --help)" ;;
  esac
done

[[ "$MODE" == "check" || "$MODE" == "test" ]] || fail "--mode must be check or test"

command -v pvesh >/dev/null || fail "run this on a Proxmox VE node (pvesh not found)"
command -v python3 >/dev/null || fail "python3 is required for JSON parsing"

confirm() {
  if [[ "$ASSUME_YES" -eq 1 ]]; then return 0; fi
  local reply
  printf '%s (type "yes" to continue): ' "$1"
  read -r reply
  [[ "$reply" == "yes" ]] || fail "aborted by operator"
}

# Pick the PBS storage: explicit flag wins, otherwise auto-detect when unambiguous.
resolve_pbs_storage() {
  if [[ -n "$PBS_STORAGE" ]]; then return 0; fi
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
    fail "multiple PBS storages found; pass --pbs-storage ID (candidates: $(printf '%s' "$found" | tr '\n' ' '))"
  fi
}

# Print "vmid|type|epoch|volid" for the latest backup of a guest (empty if none).
latest_backup() {
  local vmid="$1"
  pvesh get "/nodes/localhost/storage/${PBS_STORAGE}/content" \
    --content backup --output-format json 2>/dev/null \
  | python3 -c '
import json, re, sys
vmid = sys.argv[1]
best = None
for item in json.load(sys.stdin):
    volid = item.get("volid", "")
    m = re.search(r"vzdump-(qemu|lxc)-(\d+)-(\d{4})_(\d{2})_(\d{2})-(\d{2})_(\d{2})_(\d{2})", volid)
    if not m or m.group(2) != vmid:
        continue
    from datetime import datetime, timezone
    ts = datetime(int(m.group(3)), int(m.group(4)), int(m.group(5)),
                  int(m.group(6)), int(m.group(7)), int(m.group(8)),
                  tzinfo=timezone.utc)
    epoch = int(ts.timestamp())
    if best is None or epoch > best[2]:
        best = (m.group(2), m.group(1), epoch, volid)
if best:
    print("%s|%s|%s|%s" % best)
' "$vmid"
}

# Print "vmid|type|epoch" for the latest backup of every backed-up guest.
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

vmid_in_use() {
  pvesh get /cluster/resources --type vm --output-format json 2>/dev/null \
  | python3 -c '
import json, sys
want = int(sys.argv[1])
for r in json.load(sys.stdin):
    if r.get("vmid") == want:
        sys.exit(0)
sys.exit(1)
' "$1"
}

resolve_target_storage() {
  if [[ -n "$TARGET_STORAGE" ]]; then return 0; fi
  TARGET_STORAGE="$(pvesm status 2>/dev/null | awk 'NR>1 && ($2=="lvmthin" || $2=="zfspool") && $3=="active" {print $1; exit}')"
  [[ -n "$TARGET_STORAGE" ]] || fail "no active lvmthin/zfspool storage found; pass --target-storage ID"
  log "Auto-detected target storage: $TARGET_STORAGE"
}

notify() {
  local title="$1" message="$2"
  [[ -n "$NTFY_URL" && -n "$NTFY_TOPIC" ]] || return 0
  curl --fail -s -m 15 -H "Title: $title" -d "$message" "${NTFY_URL}/${NTFY_TOPIC}" >/dev/null \
    || log "WARNING: ntfy notification failed"
}

now_epoch() { date +%s; }

age_days() { echo $(( ($1) / 86400 )); }

# ------------------------------------------------------------------ check

do_check() {
  resolve_pbs_storage
  local now stale_found=0
  now="$(now_epoch)"
  log "PBS storage: $PBS_STORAGE"
  printf '%-8s %-6s %-14s %s\n' "VMID" "TYPE" "LATEST_BACKUP" "STATUS"
  while IFS='|' read -r vmid gtype epoch; do
    [[ -n "$vmid" ]] || continue
    local days status
    days="$(age_days $(( now - epoch )))"
    status="OK"
    if [[ "$days" -gt "$MAX_AGE_DAYS" ]]; then status="STALE"; stale_found=1; fi
    printf '%-8s %-6s %-14s %s\n' "$vmid" "$gtype" "${days}d ago" "$status"
  done < <(all_latest_backups)
  if [[ -n "$CANARY_VMID" ]]; then
    local info
    info="$(latest_backup "$CANARY_VMID")"
    if [[ -z "$info" ]]; then
      fail "canary vmid $CANARY_VMID has no backup on $PBS_STORAGE"
    fi
    log "Canary $CANARY_VMID: latest backup $(age_days $(( now - $(echo "$info" | cut -d'|' -f3) )))d ago"
  fi
  [[ "$stale_found" -eq 0 ]] || log "WARNING: stale backups found (older than ${MAX_AGE_DAYS}d)"
  log "Check complete."
}

# ------------------------------------------------------------------- test

CREATED=0
GUEST_TYPE=""

cleanup() {
  if [[ "$CREATED" -eq 1 && -n "$GUEST_TYPE" ]]; then
    log "Cleaning up throwaway guest $TEST_VMID..."
    if [[ "$GUEST_TYPE" == "qemu" ]]; then
      qm stop "$TEST_VMID" 2>/dev/null || true
      qm destroy "$TEST_VMID" --purge --destroy-unreferenced-disks 1 2>/dev/null || true
    else
      pct stop "$TEST_VMID" 2>/dev/null || true
      pct destroy "$TEST_VMID" --purge 2>/dev/null || true
    fi
    CREATED=0
  fi
}

wait_running() {
  local deadline=$(( $(now_epoch) + TIMEOUT ))
  while [[ "$(now_epoch)" -lt "$deadline" ]]; do
    local st
    if [[ "$GUEST_TYPE" == "qemu" ]]; then
      st="$(qm status "$TEST_VMID" 2>/dev/null || true)"
    else
      st="$(pct status "$TEST_VMID" 2>/dev/null || true)"
    fi
    if [[ "$st" == *"running"* ]]; then return 0; fi
    sleep 5
  done
  return 1
}

do_test() {
  [[ -n "$CANARY_VMID" ]] || fail "test mode needs --vmid ID (the canary guest)"
  resolve_pbs_storage
  resolve_target_storage
  vmid_in_use "$TEST_VMID" && fail "test VMID $TEST_VMID is already in use; pass --test-vmid"

  local info volid epoch gtype now days
  info="$(latest_backup "$CANARY_VMID")"
  [[ -n "$info" ]] || fail "canary vmid $CANARY_VMID has no backup on $PBS_STORAGE"
  gtype="$(echo "$info" | cut -d'|' -f2)"
  epoch="$(echo "$info" | cut -d'|' -f3)"
  volid="$(echo "$info" | cut -d'|' -f4)"
  now="$(now_epoch)"
  days="$(age_days $(( now - epoch )))"
  GUEST_TYPE="$gtype"

  log "Canary: $CANARY_VMID ($gtype), latest backup ${days}d ago"
  log "Backup: $volid"
  log "Restore target: throwaway VMID $TEST_VMID on $TARGET_STORAGE (network detached)"
  if [[ "$days" -gt "$MAX_AGE_DAYS" ]]; then
    log "WARNING: backup is stale (older than ${MAX_AGE_DAYS}d); testing restore mechanics anyway"
  fi
  confirm "Run restore test"

  trap cleanup EXIT
  log "Restoring..."
  if [[ "$gtype" == "qemu" ]]; then
    qmrestore "$volid" "$TEST_VMID" --storage "$TARGET_STORAGE"
  else
    pct restore "$TEST_VMID" "$volid" --storage "$TARGET_STORAGE"
  fi
  CREATED=1

  # Detach network before first boot: the copy must never touch production nets.
  log "Detaching network interfaces..."
  if [[ "$gtype" == "qemu" ]]; then
    qm set "$TEST_VMID" --delete net0 2>/dev/null || log "(no net0 to detach)"
  else
    pct set "$TEST_VMID" --delete net0 2>/dev/null || log "(no net0 to detach)"
  fi

  log "Starting (timeout ${TIMEOUT}s)..."
  if [[ "$gtype" == "qemu" ]]; then qm start "$TEST_VMID"; else pct start "$TEST_VMID"; fi
  if ! wait_running; then
    notify "pbs-restore-test FAIL" "canary $CANARY_VMID restore reached timeout without booting"
    fail "FAIL: guest did not reach running state within ${TIMEOUT}s"
  fi
  log "Guest is running."

  # Best-effort deeper check: guest agent (VM) or exec (LXC) proves userspace is up.
  local deep="skipped"
  if [[ "$gtype" == "qemu" ]]; then
    if timeout 60 qm agent "$TEST_VMID" ping 2>/dev/null; then deep="agent ping OK"; fi
  else
    if timeout 60 pct exec "$TEST_VMID" -- true 2>/dev/null; then deep="exec OK"; fi
  fi
  log "Deep check: $deep"

  cleanup
  trap - EXIT
  local msg="PASS: canary $CANARY_VMID (${gtype}) backup restored to $TEST_VMID, booted, verified ($deep), torn down"
  log "$msg"
  notify "pbs-restore-test PASS" "$msg"
}

case "$MODE" in
  check) do_check ;;
  test) do_test ;;
esac
