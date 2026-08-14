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
exec python3 server/answer_server.py --inventory inventory.json --tls-cert "$TLS_CERT" --tls-key "$TLS_KEY" "${@}"
