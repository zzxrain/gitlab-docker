#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
env_file="$root_dir/.env"

if [[ ! -f "$env_file" ]]; then
  printf 'Missing %s. Copy .env.example to .env first.\n' "$env_file" >&2
  exit 1
fi

read_env_value() {
  local key="$1"
  local fallback="$2"
  local value

  value="$(sed -n "s/^${key}=//p" "$env_file" | tail -n 1 | tr -d '\r')"
  printf '%s' "${value:-$fallback}"
}

hostname="$(read_env_value GITLAB_HOSTNAME apps.localmac.net)"
output_dir="$root_dir/secrets/ssl"
mkdir -p "$output_dir"

if [[ -e "$output_dir/$hostname.crt" || -e "$output_dir/$hostname.key" ]]; then
  printf 'Certificate or key already exists for %s; refusing to overwrite it.\n' "$hostname" >&2
  exit 1
fi

openssl req -x509 -nodes -newkey rsa:4096 -sha256 -days 825 \
  -keyout "$output_dir/$hostname.key" \
  -out "$output_dir/$hostname.crt" \
  -subj "/CN=$hostname" \
  -addext "subjectAltName=DNS:$hostname,DNS:localhost,IP:127.0.0.1"
chmod 600 "$output_dir/$hostname.key"
printf 'Created %s and %s\n' "$output_dir/$hostname.crt" "$output_dir/$hostname.key"
