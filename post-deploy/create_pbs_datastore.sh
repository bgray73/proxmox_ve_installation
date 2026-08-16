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
