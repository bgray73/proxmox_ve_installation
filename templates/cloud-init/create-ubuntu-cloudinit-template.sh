#!/usr/bin/env bash
# Create an Ubuntu cloud-init golden template on Proxmox VE.
# Optional helper — not used by the automated PVE/PBS ISO install path.
#
# Run as root on a Proxmox node:
#   sudo ./create-ubuntu-cloudinit-template.sh
#
# Environment overrides:
#   VMID              Template VMID (default: 9000)
#   STORAGE           Disk storage (default: local-lvm)
#   BRIDGE            Bridge for net0 (default: vmbr0)
#   MEMORY_MB         Memory (default: 2048)
#   CORES             vCPUs (default: 2)
#   CI_USER           cloud-init user (default: ubuntu)
#   SSH_KEYS_FILE     Public keys file (default: $HOME/.ssh/authorized_keys)
#   IMAGE_URL         Cloud image URL
#   TEMPLATE_NAME     Proxmox name (default: ubuntu-2404-cloudinit-template)
#   SNIPPET_VENDOR    cicustom vendor volume (e.g. local:snippets/vendor.yaml)
#   RESIZE_GB         If set, qemu-img resize image before import (e.g. 32)
#   SKIP_TEMPLATE     If 1, do not run qm template (leave as VM for inspection)

set -euo pipefail

VMID="${VMID:-9000}"
STORAGE="${STORAGE:-local-lvm}"
BRIDGE="${BRIDGE:-vmbr0}"
MEMORY_MB="${MEMORY_MB:-2048}"
CORES="${CORES:-2}"
CI_USER="${CI_USER:-ubuntu}"
SSH_KEYS_FILE="${SSH_KEYS_FILE:-${HOME}/.ssh/authorized_keys}"
TEMPLATE_NAME="${TEMPLATE_NAME:-ubuntu-2404-cloudinit-template}"
IMAGE_URL="${IMAGE_URL:-https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img}"
SNIPPET_VENDOR="${SNIPPET_VENDOR:-}"
RESIZE_GB="${RESIZE_GB:-}"
SKIP_TEMPLATE="${SKIP_TEMPLATE:-0}"

IMAGE_FILE="/tmp/$(basename "${IMAGE_URL}")"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run as root on a Proxmox VE node." >&2
  exit 1
fi

if ! command -v qm >/dev/null 2>&1; then
  echo "qm not found — is this a Proxmox VE node?" >&2
  exit 1
fi

if qm status "${VMID}" &>/dev/null; then
  echo "VMID ${VMID} already exists. Choose another VMID or remove it first." >&2
  exit 1
fi

echo "==> Downloading cloud image"
wget -q --show-progress -O "${IMAGE_FILE}" "${IMAGE_URL}"

if [[ -n "${RESIZE_GB}" ]]; then
  echo "==> Resizing image to ${RESIZE_GB}G"
  qemu-img resize "${IMAGE_FILE}" "${RESIZE_GB}G"
fi

echo "==> Creating VM ${VMID} (${TEMPLATE_NAME})"
qm create "${VMID}" \
  --name "${TEMPLATE_NAME}" \
  --ostype l26 \
  --memory "${MEMORY_MB}" \
  --cores "${CORES}" \
  --cpu host \
  --net0 "virtio,bridge=${BRIDGE}" \
  --agent enabled=1 \
  --serial0 socket \
  --vga serial0

echo "==> Importing disk to ${STORAGE}"
qm importdisk "${VMID}" "${IMAGE_FILE}" "${STORAGE}"

# Resolve imported volume name from config (handles local-lvm vs ZFS naming)
DISK_REF=""
while read -r line; do
  if [[ "${line}" =~ ^unused[0-9]+:(.+)$ ]]; then
    DISK_REF="${BASH_REMATCH[1]}"
    break
  fi
done < <(qm config "${VMID}")

if [[ -z "${DISK_REF}" ]]; then
  echo "Could not find imported unused disk in qm config ${VMID}" >&2
  qm config "${VMID}" >&2
  exit 1
fi

echo "==> Attaching disk ${DISK_REF} as scsi0"
qm set "${VMID}" --scsihw virtio-scsi-single \
  --scsi0 "${DISK_REF},discard=on"
qm set "${VMID}" --boot order=scsi0

echo "==> Attaching cloud-init drive"
qm set "${VMID}" --ide2 "${STORAGE}:cloudinit"

echo "==> Cloud-init defaults (user=${CI_USER}, dhcp)"
CI_ARGS=(--ciuser "${CI_USER}" --ipconfig0 ip=dhcp)
if [[ -f "${SSH_KEYS_FILE}" ]]; then
  CI_ARGS+=(--sshkeys "${SSH_KEYS_FILE}")
else
  echo "Warning: SSH keys file not found (${SSH_KEYS_FILE}); set keys on clones." >&2
fi
qm set "${VMID}" "${CI_ARGS[@]}"

if [[ -n "${SNIPPET_VENDOR}" ]]; then
  echo "==> cicustom vendor=${SNIPPET_VENDOR}"
  qm set "${VMID}" --cicustom "vendor=${SNIPPET_VENDOR}"
elif [[ -f /var/lib/vz/snippets/vendor.yaml ]]; then
  echo "==> cicustom vendor=local:snippets/vendor.yaml"
  qm set "${VMID}" --cicustom "vendor=local:snippets/vendor.yaml"
fi

rm -f "${IMAGE_FILE}"

if [[ "${SKIP_TEMPLATE}" == "1" ]]; then
  echo "==> SKIP_TEMPLATE=1 — left as VM ${VMID}. Review, then: qm template ${VMID}"
else
  echo "==> Converting to template"
  qm template "${VMID}"
  echo "Done. Template VMID=${VMID} name=${TEMPLATE_NAME}"
  echo "Clone example:"
  echo "  qm clone ${VMID} 120 --name web-01 --full"
  echo "  qm set 120 --ipconfig0 ip=10.0.1.120/24,gw=10.0.1.1"
  echo "  qm start 120"
fi
