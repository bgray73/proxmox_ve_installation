#!/usr/bin/env bash
# Run on the first PVE node only after verifying name resolution and time sync.
set -euo pipefail
[[ $# -eq 1 ]] || { echo "Usage: $0 CLUSTER_NAME" >&2; exit 2; }
command -v pvecm >/dev/null || { echo "Run this on a PVE node" >&2; exit 2; }
if pvecm status >/dev/null 2>&1; then
  echo "This node is already in a cluster; refusing." >&2
  exit 1
fi
pvecm create "$1"
echo "Cluster created. On each remaining node run: pvecm add <IP-of-this-node>"
