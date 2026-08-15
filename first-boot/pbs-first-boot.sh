#!/usr/bin/env bash
# Safe first-boot validation for Proxmox Backup Server nodes.
# Embedded into the automated ISO via proxmox-auto-install-assistant --on-first-boot.
set -euo pipefail

log() { logger -t proxmox-deploy-kit -- "$*"; echo "$*"; }
fail() { log "ERROR: $*"; exit 1; }

if ! command -v proxmox-backup-manager >/dev/null 2>&1; then
  fail "Expected Proxmox Backup Server; proxmox-backup-manager is absent"
fi

install -d -m 0700 /root/proxmox-deployment
MARKER=/root/proxmox-deployment/first-boot-complete
LAYOUT=/root/proxmox-deployment/disk-layout.txt
NETINFO=/root/proxmox-deployment/network-info.txt

# Record disk layout for later debugging (read-only).
{
  echo "# Generated $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  command -v lsblk >/dev/null && lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT,MODEL,SERIAL || true
  echo
  command -v zpool >/dev/null && zpool status 2>/dev/null || true
  command -v findmnt >/dev/null && findmnt -t zfs,ext4,xfs 2>/dev/null || true
} > "$LAYOUT" 2>/dev/null || true
chmod 0600 "$LAYOUT" 2>/dev/null || true

# Record basic network identity.
{
  echo "# Generated $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  hostname -f 2>/dev/null || hostname
  ip -br addr 2>/dev/null || true
  ip route 2>/dev/null || true
} > "$NETINFO" 2>/dev/null || true
chmod 0600 "$NETINFO" 2>/dev/null || true

# Ensure SSH is available for post-install work.
systemctl enable --now ssh 2>/dev/null || systemctl enable --now sshd 2>/dev/null || true

# Prefer chrony/systemd-timesyncd; warn but do not hard-fail on first boot.
if command -v chronyc >/dev/null 2>&1; then
  chronyc tracking >/dev/null 2>&1 || log "WARN: chrony tracking not ready yet"
elif command -v timedatectl >/dev/null 2>&1; then
  timedatectl show -p NTPSynchronized --value 2>/dev/null | grep -qx yes \
    || log "WARN: NTP not yet synchronized"
fi

# Optional guest agent for hypervisor tooling (harmless if already present).
if command -v apt-get >/dev/null 2>&1; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq >/dev/null 2>&1 || true
  apt-get install -y -qq qemu-guest-agent >/dev/null 2>&1 || true
  systemctl enable --now qemu-guest-agent 2>/dev/null || true
fi

{
  echo "product=pbs"
  echo "host=$(hostname -f 2>/dev/null || hostname)"
  echo "completed=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "$MARKER"
chmod 0600 "$MARKER"

log "PBS first-boot validation completed for $(hostname -f 2>/dev/null || hostname)"
