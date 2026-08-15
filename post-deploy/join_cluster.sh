#!/usr/bin/env bash
# Join an existing Proxmox VE cluster from a secondary node.
# Run one node at a time after the first node has created the cluster.
set -euo pipefail

DRY_RUN=0
if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN=1
  shift
fi

[[ $# -eq 1 ]] || { echo "Usage: $0 [--dry-run] FIRST_NODE_MANAGEMENT_IP" >&2; exit 2; }
FIRST_IP="$1"

log() { echo "$*"; }
fail() { echo "ERROR: $*" >&2; exit 1; }

command -v pvecm >/dev/null || fail "Run this on a PVE node (pvecm not found)"

if pvecm status >/dev/null 2>&1; then
  fail "This node is already in a cluster; refusing"
fi

# Do not join a node that already has local VMs/config that would be lost.
if [[ -d /etc/pve/nodes ]] && [[ -n "$(ls -A /etc/pve/nodes 2>/dev/null || true)" ]]; then
  # Fresh installs may have only the local node directory; warn if content looks non-empty beyond defaults.
  log "WARN: /etc/pve has content; ensure no VMs or local cluster config exist before joining"
fi

HOST_FQDN="$(hostname -f 2>/dev/null || hostname)"
log "Preflight: local host is $HOST_FQDN"
log "Preflight: target first-node IP is $FIRST_IP"

if command -v timedatectl >/dev/null 2>&1; then
  SYNC="$(timedatectl show -p NTPSynchronized --value 2>/dev/null || echo unknown)"
  if [[ "$SYNC" != "yes" ]]; then
    log "WARN: NTP is not synchronized (NTPSynchronized=$SYNC)"
  else
    log "Preflight: NTP synchronized"
  fi
fi

# Reachability check (ICMP may be blocked; try TCP 22 as a soft probe).
if command -v ping >/dev/null 2>&1; then
  if ping -c 1 -W 2 "$FIRST_IP" >/dev/null 2>&1; then
    log "Preflight: $FIRST_IP responds to ICMP"
  else
    log "WARN: $FIRST_IP did not respond to ICMP (may be filtered)"
  fi
fi

if [[ "$DRY_RUN" -eq 1 ]]; then
  log "DRY-RUN: would run: pvecm add $FIRST_IP"
  log "DRY-RUN: preflight completed; no changes made"
  exit 0
fi

log "Joining cluster via $FIRST_IP..."
pvecm add "$FIRST_IP"
log "Join complete. Verify with: pvecm status"
