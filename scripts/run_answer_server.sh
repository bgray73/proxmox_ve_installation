#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
[[ -f .env ]] || { echo "Missing .env; copy secrets.env.example and edit it" >&2; exit 2; }
[[ -f inventory.json ]] || { echo "Missing inventory.json; copy inventory.example.json and edit it" >&2; exit 2; }
set -a
# shellcheck disable=SC1091
source .env
set +a
: "${TLS_CERT:?Set TLS_CERT in .env}"
: "${TLS_KEY:?Set TLS_KEY in .env}"
# Warn (do not fail): after a token rotation the server must restart with the
# new token before the ISOs are rebuilt, so staleness is expected briefly.
if ! scripts/check_iso_freshness.sh; then
  echo "WARNING: automated ISOs are stale relative to .env ANSWER_TOKEN;" >&2
  echo "WARNING: rebuild them with scripts/build_isos.sh before deploying." >&2
fi
exec python3 server/answer_server.py --inventory inventory.json --tls-cert "$TLS_CERT" --tls-key "$TLS_KEY" "${@}"
