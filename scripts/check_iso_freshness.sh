#!/usr/bin/env bash
# Fail (exit 1) when automated ISOs exist in output/ but were built with an
# ANSWER_TOKEN different from the current .env token (e.g. after
# scripts/rotate_answer_token.sh without a rebuild). Exits 0 when no ISOs
# have been built yet or the embedded token fingerprint matches.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

[[ -f .env ]] || { echo "ERROR: Missing .env; copy secrets.env.example and edit it" >&2; exit 2; }
set -a
# shellcheck disable=SC1091
source .env
set +a
: "${ANSWER_TOKEN:?Set ANSWER_TOKEN in .env}"

shopt -s nullglob
isos=(output/*-auto.iso)
if (( ${#isos[@]} == 0 )); then
  exit 0 # nothing built yet; nothing can be stale
fi

META="output/build-meta.json"
[[ -f "$META" ]] || {
  echo "ERROR: automated ISOs exist but $META is missing (built before freshness tracking);" >&2
  echo "       rebuild both ISOs with scripts/build_isos.sh" >&2
  exit 1
}
recorded="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["answer_token_sha256"])' "$META" 2>/dev/null || true)"
current="$(printf '%s' "$ANSWER_TOKEN" | sha256sum | awk '{ print $1 }')"
if [[ "$recorded" != "$current" ]]; then
  echo "ERROR: ANSWER_TOKEN in .env is newer than the token embedded in output/*-auto.iso" >&2
  echo "       (token was rotated without a rebuild). Rebuild both ISOs with" >&2
  echo "       scripts/build_isos.sh before deploying." >&2
  exit 1
fi
echo "ISO freshness OK: embedded token matches .env ANSWER_TOKEN"
