#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 0 ]]; then
  echo "Usage: $0" >&2
  exit 2
fi

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root_dir"

if [[ ! -f .env ]]; then
  echo "Missing .env. Copy .env.example to .env first." >&2
  exit 1
fi

read_env_value() {
  local key="$1"
  local fallback="$2"
  local value

  value="$(sed -n "s/^${key}=//p" .env | tail -n 1 | tr -d '\r')"
  printf '%s' "${value:-$fallback}"
}

gitlab_hostname="$(read_env_value GITLAB_HOSTNAME apps.localmac.net)"
gitlab_https_port="$(read_env_value GITLAB_HTTPS_PORT 8445)"
caddy_root_ca_path="$(read_env_value CADDY_ROOT_CA_PATH ../jenkins-docker/certs/caddy-local-root.crt)"
if [[ "$caddy_root_ca_path" != /* ]]; then
  caddy_root_ca_path="$root_dir/$caddy_root_ca_path"
fi

if [[ ! -f "$caddy_root_ca_path" ]]; then
  printf 'Missing Caddy root CA: %s\n' "$caddy_root_ca_path" >&2
  exit 1
fi

read -r -s -p "Runner authentication token: " runner_token
printf '\n'
if [[ -z "$runner_token" ]]; then
  echo "Runner authentication token cannot be empty." >&2
  exit 1
fi

docker compose --profile runner up -d runner
docker compose exec -T runner register --non-interactive \
  --url "https://${gitlab_hostname}:${gitlab_https_port}" \
  --token "$runner_token" \
  --executor docker \
  --docker-image alpine:3.22 \
  --description "docker-runner" \
  --docker-network-mode "$(read_env_value TOOLING_EDGE_NETWORK local-tooling-edge)" \
  --docker-pull-policy if-not-present

unset runner_token
