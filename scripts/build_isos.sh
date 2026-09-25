#!/usr/bin/env bash
# Run on Debian/Proxmox x86_64 with proxmox-auto-install-assistant and xorriso installed.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
[[ $# -eq 2 ]] || { echo "Usage: $0 /path/proxmox-ve.iso /path/proxmox-backup-server.iso" >&2; exit 2; }
[[ -f .env ]] || { echo "Missing .env" >&2; exit 2; }
[[ -f inventory.json ]] || { echo "Missing inventory.json" >&2; exit 2; }
command -v proxmox-auto-install-assistant >/dev/null || { echo "Install proxmox-auto-install-assistant first" >&2; exit 2; }
command -v xorriso >/dev/null || { echo "Install xorriso first" >&2; exit 2; }
fail() { echo "ERROR: $*" >&2; exit 1; }

# Fail closed: SHA256-verify each source ISO against iso-checksums.txt
# (official hashes: https://www.proxmox.com/en/downloads) before building.
CHECKSUM_FILE="$ROOT/iso-checksums.txt"
[[ -f "$CHECKSUM_FILE" ]] || fail "Missing $CHECKSUM_FILE (see iso-checksums.txt header for format)"
verify_iso() {
  local iso="$1" base expected actual
  [[ -f "$iso" ]] || fail "ISO not found: $iso"
  base="$(basename "$iso")"
  expected="$(grep -v '^[[:space:]]*#' "$CHECKSUM_FILE" | grep -v '^[[:space:]]*$' \
    | awk -v f="$base" '$2 == f { print $1; exit }')"
  [[ -n "$expected" ]] || fail "No checksum entry for '$base' in iso-checksums.txt; add the official SHA256 for this exact ISO"
  [[ "$expected" =~ ^[0-9a-fA-F]{64}$ ]] || fail "Checksum entry for '$base' is a placeholder or malformed; paste the official 64-char SHA256 from https://www.proxmox.com/en/downloads"
  actual="$(sha256sum "$iso" | awk '{ print $1 }')"
  [[ "${actual,,}" == "${expected,,}" ]] || fail "SHA256 mismatch for '$base': expected $expected, got $actual; re-download the ISO"
  echo "Checksum OK: $base"
}
verify_iso "$1"
verify_iso "$2"
set -a
# shellcheck disable=SC1091
source .env
set +a
: "${ANSWER_URL:?Set ANSWER_URL in .env}"
: "${ANSWER_TOKEN:?Set ANSWER_TOKEN in .env}"
: "${ANSWER_CERT_FINGERPRINT:?Set ANSWER_CERT_FINGERPRINT in .env}"
[[ "$ANSWER_URL" == https://* ]] || { echo "ANSWER_URL must use HTTPS" >&2; exit 2; }
python3 scripts/validate_inventory.py inventory.json
mkdir -p output
rm -rf output/answers
python3 scripts/render_answers.py inventory.json output/answers
for answer in output/answers/*.toml; do
  proxmox-auto-install-assistant validate-answer "$answer"
done
proxmox-auto-install-assistant prepare-iso "$1" \
  --fetch-from http --url "$ANSWER_URL" --answer-auth-token "$ANSWER_TOKEN" \
  --cert-fingerprint "$ANSWER_CERT_FINGERPRINT" \
  --on-first-boot first-boot/pve-first-boot.sh \
  --output output/proxmox-ve-auto.iso
proxmox-auto-install-assistant prepare-iso "$2" \
  --fetch-from http --url "$ANSWER_URL" --answer-auth-token "$ANSWER_TOKEN" \
  --cert-fingerprint "$ANSWER_CERT_FINGERPRINT" \
  --on-first-boot first-boot/pbs-first-boot.sh \
  --output output/proxmox-backup-server-auto.iso
proxmox-auto-install-assistant inspect-iso output/proxmox-ve-auto.iso
proxmox-auto-install-assistant inspect-iso output/proxmox-backup-server-auto.iso
sha256sum output/*.iso > output/SHA256SUMS
printf '\nBuilt and inspected both ISOs. Checksums: output/SHA256SUMS\n'
