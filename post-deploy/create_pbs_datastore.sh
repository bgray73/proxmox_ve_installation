#!/usr/bin/env bash
# Create a PBS datastore only after the intended backup filesystem is mounted.
set -euo pipefail

DRY_RUN=0
if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN=1
  shift
fi

[[ $# -eq 2 ]] || { echo "Usage: $0 [--dry-run] DATASTORE_NAME /absolute/mount/path" >&2; exit 2; }
NAME="$1"
PATHNAME="$2"

log() { echo "$*"; }
fail() { echo "ERROR: $*" >&2; exit 1; }

command -v proxmox-backup-manager >/dev/null || fail "Run this on PBS (proxmox-backup-manager not found)"
[[ "$PATHNAME" = /* ]] || fail "Datastore path must be absolute"

if ! findmnt -M "$PATHNAME" >/dev/null 2>&1; then
  fail "$PATHNAME is not a mounted filesystem; refusing"
fi

# Persistence gate: a manually mounted filesystem vanishes on reboot, after
# which PBS would silently write backups into the underlying directory on the
# root filesystem. Require an /etc/fstab entry, an enabled systemd .mount
# unit, or a ZFS dataset (auto-mounted at boot by zfs-mount).
if [[ "${ALLOW_TRANSIENT_MOUNT:-0}" != "1" ]]; then
  persistent=0
  if grep -v '^[[:space:]]*#' /etc/fstab 2>/dev/null | awk '{ print $2 }' | grep -qxF -- "$PATHNAME"; then
    persistent=1
  else
    unit="$(systemd-escape -p --suffix=mount "$PATHNAME" 2>/dev/null || true)"
    if [[ -n "$unit" ]] && systemctl is-enabled --quiet "$unit" 2>/dev/null; then
      persistent=1
    elif command -v zfs >/dev/null 2>&1; then
      src="$(findmnt -no SOURCE -M "$PATHNAME" 2>/dev/null || true)"
      if [[ -n "$src" && "$src" != /dev/* ]] && zfs list -H -o name "$src" >/dev/null 2>&1; then
        persistent=1
      fi
    fi
  fi
  if [[ "$persistent" -eq 0 ]]; then
    fail "$PATHNAME is mounted but not persistent (no /etc/fstab entry, no enabled systemd .mount unit, not a ZFS dataset). After a reboot PBS would write to the root filesystem. Make the mount persistent or set ALLOW_TRANSIENT_MOUNT=1"
  fi
fi

# Show mount details for operator confirmation.
log "Preflight: mount details for $PATHNAME"
findmnt -M "$PATHNAME" || true
if command -v df >/dev/null 2>&1; then
  df -hT "$PATHNAME" || true
fi

if proxmox-backup-manager datastore show "$NAME" >/dev/null 2>&1; then
  fail "Datastore $NAME already exists; refusing"
fi

if [[ "$DRY_RUN" -eq 1 ]]; then
  log "DRY-RUN: would run: proxmox-backup-manager datastore create $NAME $PATHNAME"
  log "DRY-RUN: preflight completed; no changes made"
  exit 0
fi

log "Creating PBS datastore $NAME at $PATHNAME..."
proxmox-backup-manager datastore create "$NAME" "$PATHNAME"
log "Created PBS datastore $NAME at $PATHNAME"
log "Next: create a least-privilege API token and register this datastore in PVE."
