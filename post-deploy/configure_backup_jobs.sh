#!/usr/bin/env bash
# Codify the cluster backup job as code: creates or updates a vzdump backup
# job via pvesh so the schedule, selection, and retention live in git — not
# only in /etc/pve/jobs.cfg, where a rebuild would lose them.
#
# Default policy (see docs/BACKUP-JOBS.md):
#   one nightly job, all guests on all nodes, snapshot mode, zstd,
#   keep-daily=7 + keep-weekly=4, failures reported (mailnotification=failure).
#
# Run on any PVE node (jobs are cluster-wide in /etc/pve/jobs.cfg).
set -euo pipefail

fail() { echo "ERROR: $*" >&2; exit 1; }
log() { echo "$*"; }

usage() {
  cat <<'EOF'
Usage:
  configure_backup_jobs.sh [options]

Options:
  --job-id ID           backup job id (default: nightly-all; or env JOB_ID)
  --pbs-storage ID      PVE storage ID for the PBS target (auto-detected if
                        exactly one active PBS storage exists; or env PBS_STORAGE)
  --schedule SPEC       systemd calendar schedule (default: 02:00 daily;
                        or env SCHEDULE)
  --prune SPEC          retention, e.g. keep-daily=7,keep-weekly=4
                        (default; or env PRUNE)
  --mode MODE           snapshot|suspend|stop (default: snapshot; or env MODE)
  --compress ALG        zstd|lzo|gzip|none (default: zstd; or env COMPRESS)
  --vmids IDS           comma-separated VMIDs to back up instead of --all
                        (or env VMIDS)
  --exclude IDS         comma-separated VMIDs to skip (or env EXCLUDE)
  --node NAME           restrict the job to one node (default: all nodes;
                        or env NODE)
  --comment TEXT        job comment (or env COMMENT)
  --apply               actually create/update the job (default is check-only:
                        show what would change)
  --yes                 skip the confirmation prompt with --apply
  -h, --help            show this help

Check mode (default) is read-only and reports whether the job would be
created, updated (with a field-by-field diff), or is already up to date.
EOF
}

JOB_ID="${JOB_ID:-nightly-all}"
PBS_STORAGE="${PBS_STORAGE:-}"
SCHEDULE="${SCHEDULE:-02:00}"
PRUNE="${PRUNE:-keep-daily=7,keep-weekly=4}"
MODE="${MODE:-snapshot}"
COMPRESS="${COMPRESS:-zstd}"
VMIDS="${VMIDS:-}"
EXCLUDE="${EXCLUDE:-}"
NODE="${NODE:-}"
COMMENT="${COMMENT:-Nightly backup of all guests to PBS (managed by post-deploy/configure_backup_jobs.sh)}"
APPLY=0
ASSUME_YES=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --job-id) JOB_ID="${2:?}"; shift 2 ;;
    --pbs-storage) PBS_STORAGE="${2:?}"; shift 2 ;;
    --schedule) SCHEDULE="${2:?}"; shift 2 ;;
    --prune) PRUNE="${2:?}"; shift 2 ;;
    --mode) MODE="${2:?}"; shift 2 ;;
    --compress) COMPRESS="${2:?}"; shift 2 ;;
    --vmids) VMIDS="${2:?}"; shift 2 ;;
    --exclude) EXCLUDE="${2:?}"; shift 2 ;;
    --node) NODE="${2:?}"; shift 2 ;;
    --comment) COMMENT="${2:?}"; shift 2 ;;
    --apply) APPLY=1; shift ;;
    --yes) ASSUME_YES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) fail "unknown argument: $1 (see --help)" ;;
  esac
done

[[ "$MODE" == snapshot || "$MODE" == suspend || "$MODE" == stop ]] \
  || fail "--mode must be snapshot, suspend, or stop"

command -v pvesh >/dev/null || fail "run this on a Proxmox VE node (pvesh not found)"
command -v pvesm >/dev/null || fail "pvesm not found"
command -v python3 >/dev/null || fail "python3 is required for JSON parsing"

confirm() {
  if [[ "$ASSUME_YES" -eq 1 ]]; then return 0; fi
  local reply
  printf '%s (type "yes" to continue): ' "$1"
  read -r reply
  [[ "$reply" == "yes" ]] || fail "aborted by operator"
}

# Auto-detect the PBS storage when exactly one active PBS storage exists.
resolve_pbs_storage() {
  if [[ -n "$PBS_STORAGE" ]]; then return 0; fi
  local found
  found="$(pvesm status 2>/dev/null | awk '$2=="pbs" && $3=="active" {print $1}')"
  local count
  count="$(printf '%s' "$found" | grep -c . || true)"
  [[ "$count" -eq 1 ]] || fail "cannot auto-detect PBS storage (found $count active PBS storages); pass --pbs-storage"
  PBS_STORAGE="$found"
  log "Auto-detected PBS storage: $PBS_STORAGE"
}

resolve_pbs_storage
log "Backup job id: $JOB_ID"
log "PBS storage: $PBS_STORAGE"

# Selection: --all unless explicit VMIDs are given.
ALL=1
if [[ -n "$VMIDS" ]]; then ALL=0; fi

# Desired job definition, compared field-by-field against the cluster state.
# Built via environment variables to avoid shell-quoting pitfalls with
# comments containing spaces or special characters.
DESIRED_JSON="$(JOB_ID="$JOB_ID" PBS_STORAGE="$PBS_STORAGE" SCHEDULE="$SCHEDULE" \
  MODE="$MODE" COMPRESS="$COMPRESS" ALL="$ALL" VMIDS="$VMIDS" EXCLUDE="$EXCLUDE" \
  NODE="$NODE" PRUNE="$PRUNE" COMMENT="$COMMENT" python3 -c '
import json, os
e = os.environ
print(json.dumps({
  "id": e["JOB_ID"],
  "storage": e["PBS_STORAGE"],
  "schedule": e["SCHEDULE"],
  "mode": e["MODE"],
  "compress": e["COMPRESS"],
  "all": e["ALL"],
  "vmid": e["VMIDS"],
  "exclude": e["EXCLUDE"],
  "node": e["NODE"],
  "prune-backups": e["PRUNE"],
  "enabled": "1",
  "mailnotification": "failure",
  "comment": e["COMMENT"],
}))')"
PLAN="$(pvesh get /cluster/backup --output-format json 2>/dev/null \
  | python3 -c '
import json, sys
desired = json.loads(sys.argv[1])
COMPARE = ["storage", "schedule", "mode", "compress", "all", "vmid",
           "exclude", "node", "prune-backups", "enabled",
           "mailnotification", "comment"]

def norm(job, key):
    value = job.get(key, "")
    return "" if value is None else str(value)

jobs = json.load(sys.stdin)
existing = next((j for j in jobs if str(j.get("id")) == desired["id"]), None)

if existing is None:
    print("STATUS=create")
    for key in ["id"] + COMPARE:
        if desired[key] != "":
            print(f"SET\t{key}\t{desired[key]}")
    for key in COMPARE:
        print(f"SHOW\t{key}\t{desired[key]}")
else:
    diffs = [(k, norm(existing, k), desired[k]) for k in COMPARE
             if norm(existing, k) != desired[k]]
    if not diffs:
        print("STATUS=ok")
    else:
        print("STATUS=update")
        for key, old, new in diffs:
            print(f"DIFF\t{key}\t{old}\t{new}")
            print(f"SET\t{key}\t{new}")
' "$DESIRED_JSON")"

STATUS="$(printf '%s\n' "$PLAN" | awk -F= '/^STATUS=/ {print $2}')"

case "$STATUS" in
  ok)
    log "Backup job '$JOB_ID' is up to date."
    ;;
  create)
    log "Backup job '$JOB_ID' does not exist; would be created with:"
    printf '%s\n' "$PLAN" | awk -F'\t' '/^SHOW/ {printf "  %s: %s\n", $2, $3}'
    if [[ "$APPLY" -eq 1 ]]; then
      confirm "Create backup job '$JOB_ID'?"
      args=()
      while IFS=$'\t' read -r _ field value; do
        args+=("--$field" "$value")
      done < <(printf '%s\n' "$PLAN" | grep '^SET')
      pvesh create /cluster/backup "${args[@]}"
      log "Created backup job '$JOB_ID'."
    fi
    ;;
  update)
    log "Backup job '$JOB_ID' exists but differs; would be updated:"
    printf '%s\n' "$PLAN" | awk -F'\t' '/^DIFF/ {printf "  %s: %s -> %s\n", $2, $3, $4}'
    if [[ "$APPLY" -eq 1 ]]; then
      confirm "Update backup job '$JOB_ID'?"
      args=()
      while IFS=$'\t' read -r _ field value; do
        args+=("--$field" "$value")
      done < <(printf '%s\n' "$PLAN" | grep '^SET')
      pvesh set "/cluster/backup/${JOB_ID}" "${args[@]}"
      log "Updated backup job '$JOB_ID'."
    fi
    ;;
  *) fail "unexpected planner output (STATUS=$STATUS)" ;;
esac

if [[ "$APPLY" -eq 0 && "$STATUS" != "ok" ]]; then
  log "(check mode: no changes made; re-run with --apply to apply)"
fi
