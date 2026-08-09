#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ -f "$ROOT_DIR/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "$ROOT_DIR/.env"
  set +a
fi

hostname="${GITLAB_HOSTNAME:-gitlab.local}"
output_dir="$ROOT_DIR/secrets/ssl"
mkdir -p "$output_dir"

openssl req -x509 -nodes -newkey rsa:4096 -sha256 -days 825 \
  -keyout "$output_dir/$hostname.key" \
  -out "$output_dir/$hostname.crt" \
  -subj "/CN=$hostname" \
  -addext "subjectAltName=DNS:$hostname,DNS:localhost,IP:127.0.0.1"
chmod 600 "$output_dir/$hostname.key"
printf 'Created %s and %s\n' "$output_dir/$hostname.crt" "$output_dir/$hostname.key"

