#!/usr/bin/env bash
# Create a self-signed TLS certificate and print its SHA-256 fingerprint.
set -euo pipefail
[[ $# -eq 2 ]] || { echo "Usage: $0 DNS_NAME_OR_IP OUTPUT_DIR" >&2; exit 2; }
NAME="$1"
OUT="$2"
command -v openssl >/dev/null || { echo "openssl is required" >&2; exit 2; }
mkdir -p "$OUT"
chmod 700 "$OUT"
if python3 -c 'import ipaddress,sys; ipaddress.ip_address(sys.argv[1])' "$NAME" 2>/dev/null; then
  SAN="IP:$NAME"
else
  SAN="DNS:$NAME"
fi
openssl req -x509 -newkey rsa:3072 -sha256 -nodes -days 825 \
  -subj "/CN=$NAME" -addext "subjectAltName=$SAN" \
  -keyout "$OUT/answer-server.key" -out "$OUT/answer-server.crt"
chmod 600 "$OUT/answer-server.key"
chmod 644 "$OUT/answer-server.crt"
echo "TLS_CERT=$OUT/answer-server.crt"
echo "TLS_KEY=$OUT/answer-server.key"
printf 'ANSWER_CERT_FINGERPRINT='
openssl x509 -in "$OUT/answer-server.crt" -noout -fingerprint -sha256 | cut -d= -f2
