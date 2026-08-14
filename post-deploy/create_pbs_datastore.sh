#!/usr/bin/env bash
# Run on PBS only after the intended backup filesystem is mounted.
set -euo pipefail
[[ $# -eq 2 ]] || { echo "Usage: $0 DATASTORE_NAME /absolute/mount/path" >&2; exit 2; }
NAME="$1"
PATHNAME="$2"
command -v proxmox-backup-manager >/dev/null || { echo "Run this on PBS" >&2; exit 2; }
[[ "$PATHNAME" = /* ]] || { echo "Datastore path must be absolute" >&2; exit 2; }
findmnt -M "$PATHNAME" >/dev/null || { echo "$PATHNAME is not a mounted filesystem; refusing" >&2; exit 1; }
proxmox-backup-manager datastore show "$NAME" >/dev/null 2>&1 && { echo "Datastore $NAME already exists; refusing" >&2; exit 1; }
proxmox-backup-manager datastore create "$NAME" "$PATHNAME"
echo "Created PBS datastore $NAME at $PATHNAME"
