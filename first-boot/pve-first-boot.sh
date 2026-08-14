#!/usr/bin/env bash
set -euo pipefail
if [[ ! -d /etc/pve ]]; then
  echo "Expected Proxmox VE; /etc/pve is absent" >&2
  exit 1
fi
install -d -m 0700 /root/proxmox-deployment
{
  echo "product=pve"
  echo "host=$(hostname -f)"
  echo "completed=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > /root/proxmox-deployment/first-boot-complete
chmod 0600 /root/proxmox-deployment/first-boot-complete
systemctl enable --now ssh
logger -t proxmox-deploy-kit "PVE first-boot validation completed"
