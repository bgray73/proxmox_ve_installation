#!/usr/bin/env bash
# Generate a new high-entropy ANSWER_TOKEN, update .env, and remind the operator
# to rebuild ISOs (the token is embedded in prepared ISOs by Proxmox tooling).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

[[ -f .env ]] || { echo "Missing .env; copy secrets.env.example and edit it first" >&2; exit 2; }

NEW_TOKEN="installer:$(openssl rand -hex 24)"

if grep -q '^ANSWER_TOKEN=' .env; then
  # Portable in-place update without requiring GNU sed.
  tmp="$(mktemp)"
  awk -v tok="$NEW_TOKEN" '
    BEGIN { done=0 }
    /^ANSWER_TOKEN=/ {
      print "ANSWER_TOKEN='" tok "'"
      done=1
      next
    }
    { print }
    END {
      if (!done) print "ANSWER_TOKEN='" tok "'"
    }
  ' .env > "$tmp"
  mv "$tmp" .env
  chmod 600 .env
else
  printf "\nANSWER_TOKEN='%s'\n" "$NEW_TOKEN" >> .env
  chmod 600 .env
fi

echo "Updated ANSWER_TOKEN in .env"
echo
echo "IMPORTANT:"
echo "  1. The previous token is now invalid for new answer requests."
echo "  2. Rebuild both automated ISOs with scripts/build_isos.sh so the"
echo "     new token is embedded."
echo "  3. Protect the new ISOs; the token is present in plain text inside them."
echo "  4. Restart the answer server so it loads the new token from .env."
echo
echo "New token (also written to .env):"
echo "  $NEW_TOKEN"
