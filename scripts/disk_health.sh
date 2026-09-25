#!/usr/bin/env bash
# Disk health for ZFS pools: scrub scheduling via the systemd timers shipped
# with zfsutils-linux, zed (ZFS Event Daemon) fault alerts, and smartd disk
# monitoring — all reporting to ntfy.
#
#   check (default) : report pools, scrub status/schedule, zed + smartd state.
#                     Exits 1 if anything needs attention.
#   apply           : install/enable/configure everything (asks for confirmation).
#
# Run on each PVE node and on the PBS host. Apply is idempotent and never
# touches pool data — it only installs packages, enables timers/services, and
# writes notifier configs (existing smartd.conf is backed up first).
set -euo pipefail

fail() { echo "ERROR: $*" >&2; exit 1; }
log() { echo "$*"; }

usage() {
  cat <<'EOF'
Usage:
  disk_health.sh [--mode check|apply] [options]

Options:
  --mode check|apply   check = report only, exit 1 on issues (default);
                       apply = install/enable/configure (asks for confirmation)
  --scrub monthly|weekly|off
                       scrub schedule for every local pool (default: monthly)
  --ntfy-url URL       ntfy server base URL (or env NTFY_URL; required for apply)
  --ntfy-topic TOPIC    ntfy topic for alerts (or env NTFY_TOPIC; required for apply)
  --yes                skip the confirmation prompt in apply mode
  -h, --help           show this help

Run as root on a Proxmox VE node or the PBS host.
EOF
}

MODE="check"
SCRUB="monthly"
ASSUME_YES=0
NTFY_URL="${NTFY_URL:-}"
NTFY_TOPIC="${NTFY_TOPIC:-}"

ZEDLET="/etc/zfs/zed.d/all-ntfy.sh"
SMARTD_HOOK="/usr/local/bin/smartd-ntfy"
SMARTD_CONF="/etc/smartd.conf"
MARKER="# managed by disk_health.sh"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode) MODE="${2:?}"; shift 2 ;;
    --scrub) SCRUB="${2:?}"; shift 2 ;;
    --ntfy-url) NTFY_URL="${2:?}"; shift 2 ;;
    --ntfy-topic) NTFY_TOPIC="${2:?}"; shift 2 ;;
    --yes) ASSUME_YES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) fail "unknown argument: $1 (see --help)" ;;
  esac
done

[[ "$MODE" == "check" || "$MODE" == "apply" ]] || fail "--mode must be check or apply"
[[ "$SCRUB" == "monthly" || "$SCRUB" == "weekly" || "$SCRUB" == "off" ]] || fail "--scrub must be monthly, weekly, or off"
[[ "$(id -u)" -eq 0 ]] || fail "run as root"

ISSUES=0
note_issue() { log "ISSUE: $*"; ISSUES=$((ISSUES + 1)); }

confirm() {
  if [[ "$ASSUME_YES" -eq 1 ]]; then return 0; fi
  local reply
  printf '%s (type "yes" to continue): ' "$1"
  read -r reply
  [[ "$reply" == "yes" ]] || fail "aborted by operator"
}

pools() { zpool list -H -o name 2>/dev/null || true; }

timer_state() { # pool, weekly|monthly -> enabled|disabled
  local unit="zfs-scrub-${2}@${1}.timer"
  systemctl is-enabled "$unit" 2>/dev/null || true
}

svc_active() { systemctl is-active "$1" 2>/dev/null || true; }

# ------------------------------------------------------------ check mode

check_pool() {
  local pool="$1" health scan_line sched
  health="$(zpool list -H -o health "$pool" 2>/dev/null || echo UNKNOWN)"
  scan_line="$(zpool status "$pool" 2>/dev/null | grep -m1 'scan:' | sed 's/^ *//' || true)"
  [[ -n "$scan_line" ]] || scan_line="scan: (no status available)"
  sched="none"
  [[ "$(timer_state "$pool" weekly)" == "enabled" ]] && sched="weekly"
  [[ "$(timer_state "$pool" monthly)" == "enabled" ]] && sched="monthly"
  log "  pool ${pool}: health=${health}, scrub schedule=${sched}"
  log "    ${scan_line}"
  [[ "$health" == "ONLINE" ]] || note_issue "pool $pool health is $health"
  [[ "$sched" != "none" ]] || note_issue "pool $pool has no scrub timer enabled"
  if [[ "$scan_line" == *"none requested"* ]]; then
    note_issue "pool $pool has never been scrubbed"
  fi
}

check_zed() {
  local st
  st="$(svc_active zed)"
  if [[ "$st" == "active" ]]; then
    log "  zed: active"
  else
    note_issue "zed is not active (state: ${st:-unknown})"
  fi
  if [[ -x "$ZEDLET" ]]; then
    log "  zedlet: present ($ZEDLET)"
  else
    note_issue "ntfy zedlet missing: $ZEDLET"
  fi
}

check_smartd() {
  local st
  st="$(svc_active smartd)"
  if [[ "$st" == "active" ]]; then
    log "  smartd: active"
  else
    note_issue "smartd is not active (state: ${st:-unknown})"
  fi
  if [[ -f "$SMARTD_CONF" ]] && grep -qF "$MARKER" "$SMARTD_CONF" 2>/dev/null; then
    log "  smartd.conf: managed by disk_health.sh"
  else
    note_issue "smartd.conf is not managed by disk_health.sh"
  fi
  if [[ -x "$SMARTD_HOOK" ]]; then
    log "  smartd hook: present ($SMARTD_HOOK)"
  else
    note_issue "ntfy smartd hook missing: $SMARTD_HOOK"
  fi
  if command -v smartctl >/dev/null; then
    local dev result
    while read -r dev; do
      [[ -n "$dev" ]] || continue
      result="$(smartctl -H "$dev" 2>/dev/null | grep -m1 'overall-health' | sed 's/.*result: //' || true)"
      [[ -n "$result" ]] || result="unknown"
      log "  disk ${dev}: SMART ${result}"
      [[ "$result" == "PASSED" || "$result" == "unknown" ]] || note_issue "disk $dev SMART health: $result"
    done < <(lsblk -dn -o NAME,TYPE 2>/dev/null | awk '$2=="disk" {print "/dev/"$1}')
  else
    note_issue "smartctl not installed (smartmontools missing)"
  fi
}

do_check() {
  local pool
  log "Pools:"
  while read -r pool; do
    [[ -n "$pool" ]] || continue
    check_pool "$pool"
  done < <(pools)
  log "ZED:"
  check_zed
  log "smartd:"
  check_smartd
  if [[ "$ISSUES" -eq 0 ]]; then
    log "OK: all disk-health checks passed."
  else
    log "Found ${ISSUES} issue(s). Run with --mode apply to remediate."
  fi
  return "$ISSUES"
}

# ------------------------------------------------------------ apply mode

pkg_installed() { dpkg -s "$1" >/dev/null 2>&1; }

install_pkgs() {
  local missing=()
  local p
  for p in zfs-zed smartmontools curl; do
    pkg_installed "$p" || missing+=("$p")
  done
  if [[ "${#missing[@]}" -gt 0 ]]; then
    log "Installing: ${missing[*]}"
    apt-get update -qq
    apt-get install -y "${missing[@]}"
  else
    log "Packages already installed: zfs-zed smartmontools curl"
  fi
}

write_stream() { # dest, mode; file content on stdin. Synchronous: safe to chmod after.
  local dest="$1" mode="$2" tmp
  tmp="$(mktemp)"
  cat > "$tmp"
  if [[ -f "$dest" ]] && cmp -s "$tmp" "$dest"; then
    log "  unchanged: $dest"
  else
    log "  writing: $dest"
    install -o root -g root -m "$mode" "$tmp" "$dest"
  fi
  rm -f "$tmp"
}

apply_scrub_timers() {
  local pool unit
  while read -r pool; do
    [[ -n "$pool" ]] || continue
    for sched in weekly monthly; do
      unit="zfs-scrub-${sched}@${pool}.timer"
      if [[ "$SCRUB" == "$sched" ]]; then
        log "  enabling $unit"
        systemctl enable "$unit" --now
      else
        if [[ "$(timer_state "$pool" "$sched")" == "enabled" ]]; then
          log "  disabling $unit"
          systemctl disable "$unit" --now || true
        fi
      fi
    done
  done < <(pools)
}

apply_zed() {
  log "Configuring zed ntfy zedlet..."
  sed -e "s|__NTFY_URL__|${NTFY_URL}|g" -e "s|__NTFY_TOPIC__|${NTFY_TOPIC}|g" \
    <<'ZEDLET_EOF' | write_stream "$ZEDLET" 755
#!/bin/sh
# zedlet installed by disk_health.sh: forward interesting ZFS events to ntfy.
# Invoked for every zevent (the "all-" prefix matches all classes); the case
# statement below filters to events worth waking someone up for.
NTFY_URL="__NTFY_URL__"
NTFY_TOPIC="__NTFY_TOPIC__"

PRIORITY=""
TITLE=""
case "${ZEVENT_CLASS:-}" in
  ereport.fs.zfs.checksum|ereport.fs.zfs.io|ereport.fs.zfs.data|ereport.fs.zfs.delay|ereport.fs.zfs.probe_failure)
    PRIORITY="max"
    TITLE="ZFS FAULT on ${ZEVENT_POOL:-?}: ${ZEVENT_CLASS}"
    ;;
  statechange)
    PRIORITY="high"
    TITLE="ZFS vdev state change on ${ZEVENT_POOL:-?}"
    ;;
  scrub.finish|resilver.finish)
    PRIORITY="default"
    TITLE="ZFS ${ZEVENT_CLASS} on ${ZEVENT_POOL:-?}"
    ;;
  *)
    exit 0
    ;;
esac

BODY="pool: ${ZEVENT_POOL:-?}
class: ${ZEVENT_CLASS:-?}
vdev: ${ZEVENT_VDEV_PATH:-?}
vdev state: ${ZEVENT_VDEV_STATE_STR:-?}
time: ${ZEVENT_TIME_STRING:-?}"

curl -fsS -m 15 -H "Title: ${TITLE}" -H "Priority: ${PRIORITY}" \
  -d "${BODY}" "${NTFY_URL}/${NTFY_TOPIC}" >/dev/null 2>&1 \
  || logger -t zed-ntfy "failed to POST ${ZEVENT_CLASS:-?} for ${ZEVENT_POOL:-?}"
exit 0
ZEDLET_EOF
  # install(1) above already set root:root and 755, which satisfies zed's
  # requirement (root-owned, executable, no group/other write bits).
  systemctl enable zed --now
  systemctl restart zed
}

apply_smartd() {
  log "Configuring smartd..."
  sed -e "s|__NTFY_URL__|${NTFY_URL}|g" -e "s|__NTFY_TOPIC__|${NTFY_TOPIC}|g" \
    <<'HOOK_EOF' | write_stream "$SMARTD_HOOK" 755
#!/bin/sh
# smartd "-M exec" hook installed by disk_health.sh: POST SMART warnings to ntfy.
# smartd sets SMARTD_* env vars; the script MUST stay silent on stdout/stderr
# (smartd treats any output as an internal error).
NTFY_URL="__NTFY_URL__"
NTFY_TOPIC="__NTFY_TOPIC__"

TITLE="smartd alert: ${SMARTD_DEVICESTRING:-unknown device}"
BODY="device: ${SMARTD_DEVICE:-?} (${SMARTD_DEVICETYPE:-?})
message: ${SMARTD_MESSAGE:-?}"

curl -fsS -m 15 -H "Title: ${TITLE}" -H "Priority: max" -H "Tags: rotating_light" \
  -d "${BODY}" "${NTFY_URL}/${NTFY_TOPIC}" >/dev/null 2>&1 \
  || logger -t smartd-ntfy "failed to POST alert for ${SMARTD_DEVICE:-?}"
exit 0
HOOK_EOF

  if [[ -f "$SMARTD_CONF" ]] && grep -qF "$MARKER" "$SMARTD_CONF" 2>/dev/null; then
    log "  smartd.conf already managed; leaving in place"
  else
    if [[ -f "$SMARTD_CONF" ]]; then
      local bak
      bak="${SMARTD_CONF}.bak.$(date +%Y%m%d%H%M%S)"
      log "  backing up existing smartd.conf to $bak"
      cp -a "$SMARTD_CONF" "$bak"
    fi
    write_stream "$SMARTD_CONF" 644 <<CONF_EOF
$MARKER
# Monitor every detected disk: health, failure attributes, error/selftest logs,
# pending and uncorrectable sectors; temperature warnings at 50C / critical 60C.
# Short self-test daily at 02:00, long self-test Saturdays at 03:00.
# Alerts go to ntfy via $SMARTD_HOOK (no local mailer).
# Drives behind a Dell PERC in RAID mode are invisible here; use one line per
# physical disk instead, e.g.: /dev/sda -d megaraid,0 -a [same options]
DEVICESCAN -H -f -t -l error -l selftest -C 197 -U 198 -W 4,50,60 \\
  -s (S/../.././02|L/../../6/03) \\
  -m <nomailer> -M exec $SMARTD_HOOK
CONF_EOF
  fi
  systemctl enable smartd --now
  systemctl restart smartd
}

do_apply() {
  [[ -n "$NTFY_URL" && -n "$NTFY_TOPIC" ]] \
    || fail "apply needs --ntfy-url and --ntfy-topic (or NTFY_URL / NTFY_TOPIC env)"
  confirm "Configure disk-health monitoring on THIS host (scrub=${SCRUB}, ntfy=${NTFY_URL}/${NTFY_TOPIC})"
  install_pkgs
  log "Scrub timers (schedule: ${SCRUB}):"
  apply_scrub_timers
  apply_zed
  apply_smartd
  log "Apply complete. Current state:"
  do_check || true
}

case "$MODE" in
  check) do_check ;;
  apply) do_apply ;;
esac
