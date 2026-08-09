#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root_dir"
mkdir -p backups
docker compose exec -T gitlab gitlab-backup create
docker compose exec -T gitlab sh -c 'tar -czf /var/opt/gitlab/backups/config-$(date +%Y%m%d-%H%M%S).tgz /etc/gitlab/gitlab-secrets.json /etc/gitlab/gitlab.rb'

