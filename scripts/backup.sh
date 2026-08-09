#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root_dir"

if [[ ! -f .env ]]; then
  echo "Missing .env. Copy .env.example to .env first." >&2
  exit 1
fi

if ! docker compose ps --status running --services | grep -qx gitlab; then
  echo "GitLab is not running." >&2
  exit 1
fi

mkdir -p backups
chmod 700 backups

timestamp="$(date +%Y%m%d-%H%M%S)"
staging_dir="$(mktemp -d)"
trap 'rm -rf "$staging_dir"' EXIT

docker compose exec -T gitlab gitlab-backup create
docker compose cp gitlab:/etc/gitlab/gitlab-secrets.json "$staging_dir/gitlab-secrets.json"
docker compose cp gitlab:/etc/gitlab/gitlab.rb "$staging_dir/gitlab.rb"
cp .env docker-compose.yml "$staging_dir/"
cp -R secrets/ssl "$staging_dir/ssl"

config_archive="backups/config-${timestamp}.tgz"
tar -C "$staging_dir" -czf "$config_archive" .
chmod 600 "$config_archive"

application_backup=""
for candidate in backups/*_gitlab_backup.tar; do
  [[ -f "$candidate" ]] || continue
  if [[ -z "$application_backup" || "$candidate" -nt "$application_backup" ]]; then
    application_backup="$candidate"
  fi
done
if [[ -z "$application_backup" ]]; then
  echo "GitLab application backup was not found after backup creation." >&2
  exit 1
fi

application_backup_name="$(basename "$application_backup")"
docker compose exec -T gitlab chown "$(id -u):$(id -g)" \
  "/var/opt/gitlab/backups/${application_backup_name}"

checksum_file="backups/checksums-${timestamp}.sha256"
shasum -a 256 "$application_backup" "$config_archive" > "$checksum_file"
chmod 600 "$application_backup" "$checksum_file"

printf 'Application backup: %s\n' "$application_backup"
printf 'Configuration archive: %s\n' "$config_archive"
printf 'Checksums: %s\n' "$checksum_file"
