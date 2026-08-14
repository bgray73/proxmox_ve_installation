#!/usr/bin/env bash
# Run on a dedicated Debian subnet-router appliance, not on iDRAC/PVE/PBS.
set -euo pipefail
ROUTES="${1:-10.10.10.0/24,10.10.20.0/24}"
curl -fsSL https://tailscale.com/install.sh | sh
cat >/etc/sysctl.d/99-tailscale-router.conf <<EOF
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
EOF
sysctl --system
tailscale up --advertise-routes="$ROUTES" --advertise-tags=tag:infra-router --ssh
printf 'Complete interactive login, then approve routes and apply policy in the admin console.\n'
