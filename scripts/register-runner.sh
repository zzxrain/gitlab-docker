#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <runner-authentication-token>" >&2
  exit 2
fi

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root_dir"
set -a
# shellcheck disable=SC1091
source .env
set +a

docker compose --profile runner up -d runner
docker compose exec -T runner register --non-interactive \
  --url "https://${GITLAB_HOSTNAME}:${GITLAB_HTTPS_PORT}" \
  --token "$1" \
  --executor docker \
  --docker-image alpine:3.22 \
  --description "docker-runner" \
  --docker-network-mode gitlab-lab_gitlab \
  --docker-volumes /var/run/docker.sock:/var/run/docker.sock \
  --docker-pull-policy if-not-present

