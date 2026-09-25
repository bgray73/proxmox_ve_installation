#!/usr/bin/env bash
# Back up pbs01's local configuration so a dead OS disk doesn't take the PBS
# config with it: /etc/proxmox-backup, network config, and a point-in-time
# snapshot of pool/datastore state. Archives stay local AND are pushed to a
# PVE node. See docs/PBS-MAINTENANCE.md.
#
#   check (default) : verify tooling, archive freshness, cron presence, and
#                     offsite destination config. Exits 1 on any issue.
#   apply           : create a timestamped archive, rotate old ones, push to
#                     --dest, install the cron line (asks for confirmation).
#
# Run as root on pbs01. Read-only everywhere except its own archive
# directory and /etc/cron.d — it never touches backup data.
set -euo pipefail

fail() { echo "ERROR: $*" >&2; exit 1; }
log() { echo "$*"; }

usage() {
  cat <<'EOF'
Usage:
  pbs_config_backup.sh [--mode check|apply] [options]

Options:
  --mode check|apply   check = report only, exit 1 on issues (default);
                       apply = archive + rotate + push + install cron
  --backup-dir DIR     local archive directory
                       (default: /var/backups/pbs-config; or env PBS_BACKUP_DIR)
  --keep N             keep this many recent archives (default: 14; or env PBS_KEEP)
  --dest SCP_TARGET    scp destination for the offsite copy, e.g.
                       root@pve01:/var/backups/pbs-config/
                       (default: CHANGE_ME placeholder = disabled; or env PBS_DEST)
  --yes                skip the confirmation prompt in apply mode
  -h, --help           show this help

Install at /usr/local/sbin/pbs_config_backup.sh on pbs01 and let
--mode apply install the daily cron line for you.
EOF
}

MODE="check"
BACKUP_DIR="${PBS_BACKUP_DIR:-/var/backups/pbs-config}"
KEEP="${PBS_KEEP:-14}"
DEST="${PBS_DEST:-root@CHANGE_ME_PVE_NODE:/var/backups/pbs-config/}"
ASSUME_YES=0

# Source locations and install paths (overridable for testing).
ETC_PBS="${PBS_ETC_DIR:-/etc/proxmox-backup}"
NET_DIR="${PBS_NET_DIR:-/etc/network}"
CRON_FILE="${PBS_CRON_FILE:-/etc/cron.d/pbs-config-backup}"
SCRIPT_PATH="${PBS_SCRIPT_PATH:-/usr/local/sbin/pbs_config_backup.sh}"
STAMP="${PBS_STAMP:-$(date +%Y%m%d-%H%M%S)}"
ARCHIVE_PREFIX="pbs-config-"
CRON_MARKER="# managed by pbs_config_backup.sh"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode) MODE="${2:?}"; shift 2 ;;
    --backup-dir) BACKUP_DIR="${2:?}"; shift 2 ;;
    --keep) KEEP="${2:?}"; shift 2 ;;
    --dest) DEST="${2:?}"; shift 2 ;;
    --yes) ASSUME_YES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) fail "unknown argument: $1 (see --help)" ;;
  esac
done

[[ "$MODE" == "check" || "$MODE" == "apply" ]] || fail "--mode must be check or apply"
[[ "$KEEP" =~ ^[0-9]+$ ]] && [[ "$KEEP" -ge 1 ]] || fail "--keep must be a positive integer"

dest_configured() { [[ "$DEST" != *CHANGE_ME* ]]; }

confirm() {
  [[ "$ASSUME_YES" == "1" ]] && return 0
  local ans
  read -r -p "$1 [type 'yes' to continue]: " ans
  [[ "$ans" == "yes" ]] || fail "aborted"
}

latest_archive() {
  # Newest own archive by mtime, empty when none exist.
  find "$BACKUP_DIR" -maxdepth 1 -name "${ARCHIVE_PREFIX}*.tar.gz" -printf '%T@ %p\n' 2>/dev/null \
    | sort -rn | head -1 | cut -d' ' -f2-
}

cron_line() {
  printf '0 3 * * * root %s --mode apply --yes >/dev/null\n' "$SCRIPT_PATH"
}

cron_ok() {
  [[ -f "$CRON_FILE" ]] && grep -qF "$CRON_MARKER" "$CRON_FILE" 2>/dev/null
}

do_check() {
  local issues=0
  local latest age_h now mtime

  command -v tar >/dev/null 2>&1 || { log "ISSUE: tar not found"; issues=$((issues+1)); }
  if command -v proxmox-backup-manager >/dev/null 2>&1; then
    log "OK: proxmox-backup-manager present"
  else
    log "ISSUE: proxmox-backup-manager not found (run this on pbs01)"
    issues=$((issues+1))
  fi

  latest="$(latest_archive)"
  if [[ -z "$latest" ]]; then
    log "ISSUE: no archives in $BACKUP_DIR yet"
    issues=$((issues+1))
  else
    now="$(date +%s)"
    mtime="$(stat -c %Y "$latest")"
    age_h=$(( (now - mtime) / 3600 ))
    if [[ "$age_h" -gt 48 ]]; then
      log "ISSUE: latest archive $latest is ${age_h}h old (> 48h)"
      issues=$((issues+1))
    else
      log "OK: latest archive $latest (${age_h}h old)"
    fi
  fi

  if cron_ok; then
    log "OK: cron installed ($CRON_FILE)"
  else
    log "ISSUE: cron line missing; suggested $CRON_FILE content:"
    log "  $CRON_MARKER"
    log "  $(cron_line)"
    issues=$((issues+1))
  fi

  if dest_configured; then
    log "OK: offsite destination configured ($DEST)"
  else
    log "ISSUE: offsite copy disabled — set --dest (or env PBS_DEST); the local archive is a single point of failure"
    issues=$((issues+1))
  fi

  if [[ "$issues" -eq 0 ]]; then
    log "Check complete: all OK."
    return 0
  else
    log "Check complete: $issues issue(s)."
    return 1
  fi
}

gather_staging() {
  # Populate $1 (a staging dir) with everything the archive must contain.
  local stage="$1"
  mkdir -p "$stage/etc-proxmox-backup" "$stage/network"

  if [[ -d "$ETC_PBS" ]]; then
    cp -a "$ETC_PBS/." "$stage/etc-proxmox-backup/"
  else
    log "WARNING: $ETC_PBS not found; skipping"
  fi
  [[ -f "$NET_DIR/interfaces" ]] && cp -a "$NET_DIR/interfaces" "$stage/network/"
  [[ -d "$NET_DIR/interfaces.d" ]] && cp -a "$NET_DIR/interfaces.d" "$stage/network/"

  if command -v zpool >/dev/null 2>&1; then
    zpool status >"$stage/zpool-status.txt" 2>&1 || true
    zpool list >"$stage/zpool-list.txt" 2>&1 || true
  fi
  if command -v proxmox-backup-manager >/dev/null 2>&1; then
    proxmox-backup-manager datastore list >"$stage/datastore-list.txt" 2>&1 || true
    proxmox-backup-manager cert info >"$stage/cert-info.txt" 2>&1 || true
  fi
  date -u +"backup taken: %Y-%m-%dT%H:%M:%SZ" >"$stage/README.txt"
}

rotate_archives() {
  # Keep the KEEP newest own archives; delete older ones only.
  local -a old
  mapfile -t old < <(find "$BACKUP_DIR" -maxdepth 1 -name "${ARCHIVE_PREFIX}*.tar.gz" \
    -printf '%T@ %p\n' | sort -n | cut -d' ' -f2-)
  local total="${#old[@]}"
  if [[ "$total" -gt "$KEEP" ]]; then
    local drop=$((total - KEEP)) i
    for ((i=0; i<drop; i++)); do
      log "Rotating out old archive: ${old[$i]}"
      rm -f "${old[$i]}"
    done
  fi
}

install_cron() {
  local want
  want="$(printf '%s\n%s' "$CRON_MARKER" "$(cron_line)")"
  if cron_ok && [[ "$(cat "$CRON_FILE")" == "$want" ]]; then
    log "Cron already installed and current."
    return 0
  fi
  log "Installing cron: $CRON_FILE"
  printf '%s\n' "$want" >"$CRON_FILE"
  chmod 644 "$CRON_FILE"
}

do_apply() {
  if [[ "${PBS_SKIP_ROOT_CHECK:-0}" != "1" && "$EUID" -ne 0 ]]; then
    fail "run as root on pbs01"
  fi
  command -v tar >/dev/null 2>&1 || fail "tar not found"

  local archive="$BACKUP_DIR/${ARCHIVE_PREFIX}${STAMP}.tar.gz"
  log "Backup dir : $BACKUP_DIR"
  log "Archive    : $archive"
  log "Keep       : $KEEP most recent"
  if dest_configured; then log "Offsite    : $DEST"; else log "Offsite    : disabled (placeholder --dest)"; fi
  confirm "Create PBS config backup"

  mkdir -p "$BACKUP_DIR"
  [[ -e "$archive" ]] && fail "archive $archive already exists; refusing to overwrite"

  local stage
  stage="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '$stage'" EXIT
  gather_staging "$stage"
  tar -czf "$archive" -C "$stage" .
  chmod 600 "$archive"
  log "Wrote $archive"
  trap - EXIT
  rm -rf "$stage"

  rotate_archives

  if dest_configured; then
    command -v scp >/dev/null 2>&1 || fail "scp not found; cannot push to $DEST"
    log "Pushing archive to $DEST"
    scp "$archive" "$DEST" || fail "scp to $DEST failed (check SSH keys / host reachability)"
  else
    log "WARNING: offsite copy skipped — set --dest (or env PBS_DEST) to a real target"
  fi

  install_cron
  log "Done."
}

case "$MODE" in
  check) do_check ;;
  apply) do_apply ;;
esac
