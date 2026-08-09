#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
env_file="$root_dir/.env"
network_name="local-tooling-edge"

if [[ -f "$env_file" ]]; then
  configured_name="$(sed -n 's/^TOOLING_EDGE_NETWORK=//p' "$env_file" | tail -n 1 | tr -d '\r')"
  network_name="${configured_name:-$network_name}"
fi

if ! docker network inspect "$network_name" >/dev/null 2>&1; then
  docker network create --driver bridge "$network_name" >/dev/null
fi

printf 'Shared tooling network ready: %s\n' "$network_name"
