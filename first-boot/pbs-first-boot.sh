#!/usr/bin/env bash
set -euo pipefail
if ! command -v proxmox-backup-manager >/dev/null; then
  echo "Expected Proxmox Backup Server; proxmox-backup-manager is absent" >&2
  exit 1
fi
install -d -m 0700 /root/proxmox-deployment
{
  echo "product=pbs"
  echo "host=$(hostname -f)"
  echo "completed=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > /root/proxmox-deployment/first-boot-complete
chmod 0600 /root/proxmox-deployment/first-boot-complete
systemctl enable --now ssh
logger -t proxmox-deploy-kit "PBS first-boot validation completed"
