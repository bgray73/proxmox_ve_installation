#!/usr/bin/env bash
# Firmware maintenance for Dell PowerEdge nodes (Dell System Update) and the
# Supermicro node (Supermicro Update Manager).
#
# Dell DSU works two ways:
#   --via idrac : DSU on this workstation talks to iDRACs over the network.
#                 Works before any OS is installed (pre-Proxmox deployment).
#   --via local : DSU runs on the Dell host itself (Proxmox VE is Debian-based,
#                 which Dell documents DSU as working with).
# Supermicro SUM runs in-band on the host (needs /dev/ipmi0). Update BMC first,
# then BIOS -- never both at the same time.
#
# Default mode is "check" (preview only). "apply" always asks for confirmation.
set -euo pipefail

fail() { echo "ERROR: $*" >&2; exit 1; }
log() { echo "$*"; }

usage() {
  cat <<'EOF'
Usage:
  update_firmware.sh dell [--mode check|apply] --via idrac --idrac-list FILE [--reboot]
  update_firmware.sh dell [--mode check|apply] --via idrac --target IDRAC_IP [--reboot]
  update_firmware.sh dell [--mode check|apply] --via local [--reboot]
  update_firmware.sh supermicro [--mode check|apply] [--sum-bin PATH]
                               [--bmc-file FILE] [--bios-file FILE] [--reboot]

Options:
  --mode check|apply   check = preview/inventory only (default); apply = install updates
  --via idrac|local    Dell only: talk to iDRACs over the network, or run on this host
  --target IP          single iDRAC IP (with --via idrac)
  --idrac-list FILE    file with "NAME IP" per line, "#" comments allowed (with --via idrac)
  --idrac-user USER    iDRAC username (or env IDRAC_USER; env preferred over flags)
  --idrac-pass PASS    iDRAC password (or env IDRAC_PASS)
  --sum-bin PATH       SUM binary (default: sum on PATH)
  --bmc-file FILE      BMC firmware image (supermicro apply)
  --bios-file FILE     BIOS firmware image (supermicro apply)
  --reboot             allow the tool to reboot the target to apply staged updates
  -h, --help           show this help

Credentials: prefer IDRAC_USER / IDRAC_PASS env vars; flags end up in shell history.
Safety: nodes are processed serially. On a Proxmox cluster, update ONE node at a
time and verify quorum/health before moving to the next. See docs/FIRMWARE.md.
EOF
}

VENDOR=""
MODE="check"
VIA=""
TARGET=""
IDRAC_LIST=""
REBOOT=0
IDRAC_USER="${IDRAC_USER:-}"
IDRAC_PASS="${IDRAC_PASS:-}"
SUM_BIN="${SUM_BIN:-sum}"
BMC_FILE=""
BIOS_FILE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    dell|supermicro) VENDOR="$1"; shift ;;
    --mode) MODE="${2:?}"; shift 2 ;;
    --via) VIA="${2:?}"; shift 2 ;;
    --target) TARGET="${2:?}"; shift 2 ;;
    --idrac-list) IDRAC_LIST="${2:?}"; shift 2 ;;
    --idrac-user) IDRAC_USER="${2:?}"; shift 2 ;;
    --idrac-pass) IDRAC_PASS="${2:?}"; shift 2 ;;
    --sum-bin) SUM_BIN="${2:?}"; shift 2 ;;
    --bmc-file) BMC_FILE="${2:?}"; shift 2 ;;
    --bios-file) BIOS_FILE="${2:?}"; shift 2 ;;
    --reboot) REBOOT=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) fail "unknown argument: $1 (see --help)" ;;
  esac
done

[[ "$VENDOR" == "dell" || "$VENDOR" == "supermicro" ]] || fail "first argument must be 'dell' or 'supermicro'"
[[ "$MODE" == "check" || "$MODE" == "apply" ]] || fail "--mode must be check or apply"

confirm() {
  local prompt="$1" reply
  printf '%s (type "yes" to continue): ' "$prompt"
  read -r reply
  [[ "$reply" == "yes" ]] || fail "aborted by operator"
}

require_root() {
  [[ "${EUID:-$(id -u)}" -eq 0 ]] || fail "run as root for this operation"
}

# ---------------------------------------------------------------- Dell (DSU)

dell_require_dsu() {
  command -v dsu >/dev/null || {
    echo "Dell System Update (dsu) is not installed." >&2
    echo "Install it from Dell, then re-run:" >&2
    echo "  1. Download the DSU Linux DUP from Dell support (search 'Dell System Update')" >&2
    echo "  2. chmod +x <file>.BIN && sudo ./<file>.BIN" >&2
    echo "Dell documents DSU as working on Debian-based distributions such as Proxmox VE." >&2
    exit 2
  }
}

dell_idrac_targets() {
  # Prints "NAME IP" lines, one per target.
  if [[ -n "$TARGET" ]]; then
    printf 'idrac %s\n' "$TARGET"
  elif [[ -n "$IDRAC_LIST" ]]; then
    [[ -f "$IDRAC_LIST" ]] || fail "iDRAC list not found: $IDRAC_LIST"
    grep -v '^[[:space:]]*#' "$IDRAC_LIST" | grep -v '^[[:space:]]*$' \
      | awk 'NF >= 2 { print $1, $2 }'
  else
    fail "with --via idrac, give --target IDRAC_IP or --idrac-list FILE"
  fi
}

dell_remote_args() {
  local ip="$1"
  [[ -n "$IDRAC_USER" ]] || fail "iDRAC username missing: set IDRAC_USER or pass --idrac-user"
  [[ -n "$IDRAC_PASS" ]] || fail "iDRAC password missing: set IDRAC_PASS or pass --idrac-pass"
  if [[ "$IDRAC_USER" == *[@:]* || "$IDRAC_PASS" == *[@:]* ]]; then
    fail "iDRAC user/password must not contain '@' or ':' (DSU remote syntax limitation)"
  fi
  printf '%s' "--remote=${IDRAC_USER}:${IDRAC_PASS}@${ip} --rsystemtype=idrac"
}

dell_flow() {
  dell_require_dsu
  local dsu_args
  if [[ "$MODE" == "check" ]]; then
    dsu_args="--preview"
  else
    dsu_args="--non-interactive"
    [[ "$REBOOT" -eq 1 ]] && dsu_args="$dsu_args --reboot"
  fi

  if [[ "$VIA" == "local" ]]; then
    require_root
    local maker
    maker="$(dmidecode -s system-manufacturer 2>/dev/null || true)"
    [[ "$maker" == *Dell* ]] || fail "this host reports manufacturer '${maker:-unknown}', not Dell; use --via idrac for remote updates"
    log "Local DSU $MODE on $maker"
    log "Running: dsu $dsu_args"
    if [[ "$MODE" == "apply" ]]; then
      confirm "Apply all applicable Dell firmware updates on THIS host"
    fi
    # shellcheck disable=SC2086
    dsu $dsu_args
    return
  fi

  if [[ "$VIA" == "idrac" ]]; then
    local remote_args
    # NOTE: the target list comes in on fd 3 so stdin stays free for confirm().
    while read -r name ip <&3; do
      [[ -n "$ip" ]] || continue
      log "=== $name ($ip): DSU $MODE via iDRAC ==="
      remote_args="$(dell_remote_args "$ip")"
      log "Running: dsu $dsu_args $remote_args"
      if [[ "$MODE" == "apply" ]]; then
        confirm "Apply all applicable firmware updates to $name ($ip)"
      fi
      # shellcheck disable=SC2086
      dsu $dsu_args $remote_args
      if [[ "$MODE" == "apply" && "$REBOOT" -eq 0 ]]; then
        log "NOTE: staged updates on $name need a reboot to take effect; reboot via iDRAC when ready."
      fi
    done 3< <(dell_idrac_targets)
    return
  fi

  fail "dell needs --via idrac or --via local"
}

# ------------------------------------------------------- Supermicro (SUM)

supermicro_require_sum() {
  [[ -x "$SUM_BIN" || "$(command -v "$SUM_BIN")" != "" ]] || {
    echo "Supermicro Update Manager not found at '$SUM_BIN'." >&2
    echo "Download SUM from Supermicro (free registration), extract it, then re-run" >&2
    echo "with --sum-bin /path/to/sum (or put sum on PATH)." >&2
    exit 2
  }
}

supermicro_flow() {
  require_root
  supermicro_require_sum
  local maker
  maker="$(dmidecode -s system-manufacturer 2>/dev/null || true)"
  [[ "$maker" == *Supermicro* ]] || fail "this host reports manufacturer '${maker:-unknown}', not Supermicro"
  # In-band SUM talks to the BMC over IPMI KCS.
  modprobe ipmi_si ipmi_devintf 2>/dev/null || true
  if [[ ! -e /dev/ipmi0 && ! -e /dev/ipmi/0 ]]; then
    fail "no IPMI device found; in-band SUM needs ipmi_si/ipmi_devintf and /dev/ipmi0"
  fi

  if [[ "$MODE" == "check" ]]; then
    log "BIOS version: $(dmidecode -s bios-version 2>/dev/null || echo unknown)"
    log "BMC info:"
    "$SUM_BIN" -c GetBmcInfo
    return
  fi

  [[ -n "$BMC_FILE" || -n "$BIOS_FILE" ]] || fail "apply needs --bmc-file and/or --bios-file"
  [[ -z "$BMC_FILE" || -f "$BMC_FILE" ]] || fail "BMC file not found: $BMC_FILE"
  [[ -z "$BIOS_FILE" || -f "$BIOS_FILE" ]] || fail "BIOS file not found: $BIOS_FILE"
  log "Planned order: BMC first, then BIOS (never simultaneously)."
  [[ -n "$BMC_FILE" ]] && log "  BMC:  $BMC_FILE"
  [[ -n "$BIOS_FILE" ]] && log "  BIOS: $BIOS_FILE (settings preserved)"
  confirm "Flash firmware on THIS Supermicro host"
  if [[ -n "$BMC_FILE" ]]; then
    log "Updating BMC (BMC will reset; config is preserved by default)..."
    "$SUM_BIN" -c UpdateBmc --file "$BMC_FILE"
    printf 'BMC update issued. Press Enter once the BMC is reachable again...'
    read -r _
  fi
  if [[ -n "$BIOS_FILE" ]]; then
    log "Updating BIOS..."
    if [[ "$REBOOT" -eq 1 ]]; then
      "$SUM_BIN" -c UpdateBios --file "$BIOS_FILE" --preserve_setting --reboot
    else
      "$SUM_BIN" -c UpdateBios --file "$BIOS_FILE" --preserve_setting
      log "NOTE: reboot this host to complete the BIOS update."
    fi
  fi
}

case "$VENDOR" in
  dell) dell_flow ;;
  supermicro) supermicro_flow ;;
esac
log "Done."
