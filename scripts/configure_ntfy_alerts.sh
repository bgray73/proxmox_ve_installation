#!/usr/bin/env bash
# Wire Proxmox VE notifications to the ntfy LXC: creates a webhook notification
# target and a severity-based matcher. Additive-only: existing targets,
# matchers, and the stock default-matcher are left untouched.
#
#   default : report current state and what --apply would change
#   --apply : create the missing pieces (asks for confirmation),
#             then send a test notification
#
# Run on exactly one PVE node: /etc/pve/notifications.cfg is cluster-wide
# state replicated by pmxcfs.
#
# NOTIFICATIONS_CFG overrides the config path (testing hook; default
# /etc/pve/notifications.cfg).
set -euo pipefail

fail() { echo "ERROR: $*" >&2; exit 1; }
log() { echo "$*"; }

usage() {
  cat <<'EOF'
Usage:
  configure_ntfy_alerts.sh [--apply] [options]

Options:
  --apply              create the webhook target + matcher (asks for confirmation),
                       then send a test notification. Default is check-only.
  --target-name NAME   webhook target name (default: ntfy-proxmox)
  --matcher-name NAME  matcher name (default: ntfy-failures)
  --ntfy-host HOST     ntfy server host/IP (default: 10.10.41.14; or env NTFY_HOST)
  --ntfy-topic TOPIC   ntfy topic (default: proxmox-alerts; or env NTFY_TOPIC)
  --yes                skip the confirmation prompt
  -h, --help           show this help

Run on one Proxmox VE node. See docs/NOTIFICATIONS.md.
EOF
}

APPLY=0
TARGET_NAME="ntfy-proxmox"
MATCHER_NAME="ntfy-failures"
NTFY_HOST="${NTFY_HOST:-10.10.41.14}"
NTFY_TOPIC="${NTFY_TOPIC:-proxmox-alerts}"
ASSUME_YES=0
NOTIFICATIONS_CFG="${NOTIFICATIONS_CFG:-/etc/pve/notifications.cfg}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply) APPLY=1; shift ;;
    --target-name) TARGET_NAME="${2:?}"; shift 2 ;;
    --matcher-name) MATCHER_NAME="${2:?}"; shift 2 ;;
    --ntfy-host) NTFY_HOST="${2:?}"; shift 2 ;;
    --ntfy-topic) NTFY_TOPIC="${2:?}"; shift 2 ;;
    --yes) ASSUME_YES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) fail "unknown argument: $1 (see --help)" ;;
  esac
done

command -v pvesh >/dev/null || fail "run this on a Proxmox VE node (pvesh not found)"

confirm() {
  if [[ "$ASSUME_YES" -eq 1 ]]; then return 0; fi
  local reply
  printf '%s (type "yes" to continue): ' "$1"
  read -r reply
  [[ "$reply" == "yes" ]] || fail "aborted by operator"
}

b64() { printf '%s' "$1" | base64 -w0; }

target_exists() {
  [[ -f "$NOTIFICATIONS_CFG" ]] && grep -q "^webhook: ${TARGET_NAME}$" "$NOTIFICATIONS_CFG"
}

matcher_exists() {
  [[ -f "$NOTIFICATIONS_CFG" ]] && grep -q "^matcher: ${MATCHER_NAME}$" "$NOTIFICATIONS_CFG"
}

do_check() {
  if target_exists; then
    log "Target '$TARGET_NAME': present"
  else
    log "Target '$TARGET_NAME': missing (would create webhook -> http://${NTFY_HOST}/<topic>)"
  fi
  if matcher_exists; then
    log "Matcher '$MATCHER_NAME': present"
  else
    log "Matcher '$MATCHER_NAME': missing (would route severity warning,error -> $TARGET_NAME)"
  fi
  if target_exists && matcher_exists; then
    log "Already configured. Send a test with: pvesh create /cluster/notifications/targets/${TARGET_NAME}/test"
  else
    log "Run with --apply to create the missing pieces."
  fi
}

do_apply() {
  local -a plan=()
  if ! target_exists; then
    plan+=("create webhook target '$TARGET_NAME' -> http://${NTFY_HOST}/<ntfy topic '${NTFY_TOPIC}'>")
  fi
  if ! matcher_exists; then
    plan+=("create matcher '$MATCHER_NAME' (severity warning,error -> $TARGET_NAME)")
  fi

  if [[ "${#plan[@]}" -eq 0 ]]; then
    log "Already configured; nothing to create."
  else
    if ! curl -s -m 10 -o /dev/null "http://${NTFY_HOST}/" 2>/dev/null; then
      log "WARNING: cannot reach ntfy at http://${NTFY_HOST}/ from this node; continuing anyway"
    fi
    log "Plan:"
    printf '  - %s\n' "${plan[@]}"
    confirm "Apply notification configuration"
    if ! target_exists; then
      log "Creating webhook target '$TARGET_NAME'..."
      pvesh create /cluster/notifications/endpoints/webhook \
        --name "$TARGET_NAME" \
        --method post \
        --url "http://${NTFY_HOST}/{{ secrets.topic }}" \
        --header "name=Title,value=$(b64 '{{ title }}')" \
        --header "name=Markdown,value=$(b64 'yes')" \
        --body "$(b64 '{{ message }}')" \
        --secret "name=topic,value=$(b64 "$NTFY_TOPIC")" \
        --comment "ntfy alerts (Terraform: ntfy LXC)"
    fi
    if ! matcher_exists; then
      log "Creating matcher '$MATCHER_NAME'..."
      pvesh create /cluster/notifications/matchers \
        --name "$MATCHER_NAME" \
        --match-severity warning,error \
        --target "$TARGET_NAME" \
        --comment "Backup failures, replication errors, fencing -> ntfy"
    fi
  fi

  log "Sending test notification..."
  pvesh create "/cluster/notifications/targets/${TARGET_NAME}/test"
  log "Test sent. Confirm it arrives on ntfy topic '${NTFY_TOPIC}' (http://${NTFY_HOST})."
}

if [[ "$APPLY" -eq 1 ]]; then
  do_apply
else
  do_check
fi
