#!/usr/bin/env bash
# Create a new Proxmox VE cluster on the first node.
# Run only after name resolution and time sync are healthy.
set -euo pipefail

DRY_RUN=0
if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN=1
  shift
fi

[[ $# -eq 1 ]] || { echo "Usage: $0 [--dry-run] CLUSTER_NAME" >&2; exit 2; }
CLUSTER_NAME="$1"

log() { echo "$*"; }
fail() { echo "ERROR: $*" >&2; exit 1; }

command -v pvecm >/dev/null || fail "Run this on a PVE node (pvecm not found)"
command -v hostname >/dev/null || fail "hostname command missing"

if pvecm status >/dev/null 2>&1; then
  fail "This node is already in a cluster; refusing"
fi

HOST_FQDN="$(hostname -f 2>/dev/null || hostname)"
log "Preflight: local host is $HOST_FQDN"

# Hard gate on time sync: Corosync/cluster operations are sensitive to clock
# skew. Override only if you know what you are doing: ALLOW_NTP_UNSYNCED=1.
if command -v timedatectl >/dev/null 2>&1; then
  SYNC="$(timedatectl show -p NTPSynchronized --value 2>/dev/null || echo unknown)"
  if [[ "$SYNC" != "yes" ]]; then
    if [[ "${ALLOW_NTP_UNSYNCED:-0}" == "1" ]]; then
      log "WARN: NTP is not synchronized (NTPSynchronized=$SYNC); continuing due to ALLOW_NTP_UNSYNCED=1"
    else
      fail "NTP is not synchronized (NTPSynchronized=$SYNC). Cluster operations require synced clocks; fix time sync (chrony/systemd-timesyncd) and re-run, or explicitly override with ALLOW_NTP_UNSYNCED=1"
    fi
  else
    log "Preflight: NTP synchronized"
  fi
fi

# Resolve own FQDN if possible.
if command -v getent >/dev/null 2>&1; then
  if getent hosts "$HOST_FQDN" >/dev/null 2>&1; then
    log "Preflight: $HOST_FQDN resolves"
  else
    log "WARN: $HOST_FQDN does not resolve via getent; fix DNS or /etc/hosts before joining other nodes"
  fi
fi

if [[ "$DRY_RUN" -eq 1 ]]; then
  log "DRY-RUN: would run: pvecm create $CLUSTER_NAME"
  log "DRY-RUN: preflight completed; no changes made"
  exit 0
fi

log "Creating cluster '$CLUSTER_NAME'..."
pvecm create "$CLUSTER_NAME"
log "Cluster created."
log "On each remaining node, one at a time, run:"
log "  post-deploy/join_cluster.sh <management-IP-of-this-node>"
log "or: pvecm add <management-IP-of-this-node>"
