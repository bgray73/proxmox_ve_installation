#!/usr/bin/env bash
set -euo pipefail
[[ $(id -u) -eq 0 ]] || { echo "Run as root" >&2; exit 2; }
[[ -d /opt/proxmox-deploy-kit ]] || { echo "Copy repo to /opt/proxmox-deploy-kit first" >&2; exit 2; }
id proxmox-answer >/dev/null 2>&1 || useradd --system --home-dir /nonexistent --shell /usr/sbin/nologin proxmox-answer
chown -R root:proxmox-answer /opt/proxmox-deploy-kit
find /opt/proxmox-deploy-kit -type d -exec chmod 0750 {} +
chmod 0640 /opt/proxmox-deploy-kit/.env /opt/proxmox-deploy-kit/inventory.json
chmod 0640 /opt/proxmox-deploy-kit/tls/answer-server.crt /opt/proxmox-deploy-kit/tls/answer-server.key
install -m 0644 /opt/proxmox-deploy-kit/systemd/proxmox-answer-server.service /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now proxmox-answer-server
