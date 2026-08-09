GITLAB CE DOCKER COMPOSE LAB
============================

Purpose and architecture
------------------------
This repository runs a pinned GitLab Community Edition (CE) server with HTTPS and
an optional Docker executor runner. It deliberately resembles a small enterprise
installation without introducing an external database, object storage, load
balancer, or Kubernetes. GitLab Omnibus owns PostgreSQL, Redis, NGINX, Gitaly, and
Prometheus inside one persistent server container. Named volumes separate config,
logs, application data, and runner state. Backups are exported to ./backups.

CE is recommended for a permanent personal lab: it is free to use and includes
repositories, merge requests, the container registry, and CI/CD. The same GitLab
EE image can run without a paid license and exposes the Free tier, but it adds no
necessary capability here. Migrating later means following GitLab's documented
CE-to-EE procedure and changing the image only at a supported version boundary.

The server is pinned to 18.3.6-ce.0 rather than latest. Pinning makes deployments
repeatable and upgrades deliberate. Always check GitLab's current supported and
required upgrade paths before using this version in a new installation.

Prerequisites
-------------
* macOS with OrbStack and its Docker compatibility enabled (or Docker Engine with
  Docker Compose v2 on Linux).
* At least 8 GB RAM allocated to the container runtime; 4 CPU cores and 20 GB free
  disk space are practical lab minimums.
* OpenSSL, which is already available on macOS.

GitLab's server image is published for linux/amd64. docker-compose.yml explicitly
selects that platform, so an M-series Mac runs it through OrbStack emulation. The
first start can be slow and production performance should not be inferred from it.

Deployment from zero to one
---------------------------
1. Clone and configure:

     git clone <this-repository-url>
     cd gitlab-docker
     cp .env.example .env

   Keep GITLAB_HTTPS_PORT at 443 for the simplest URLs. If it conflicts locally,
   change it consistently in .env. Add this line to /etc/hosts:

     127.0.0.1 gitlab.local

2. Generate a self-signed lab certificate and trust it:

     ./scripts/generate-certificate.sh
     sudo security add-trusted-cert -d -r trustRoot \
       -k /Library/Keychains/System.keychain secrets/ssl/gitlab.local.crt

   For shared/internal use, replace both files with a certificate and unencrypted
   key issued by the organization's CA. Their basename must equal GITLAB_HOSTNAME.
   Never commit private keys. Public DNS plus an edge proxy and an ACME certificate
   is preferable for an internet-accessible deployment.

3. Validate and start GitLab:

     docker compose config --quiet
     docker compose pull gitlab
     docker compose up -d gitlab
     docker compose ps

   Initialization commonly takes several minutes. Follow it with:

     docker compose logs -f gitlab

4. Retrieve the one-time root password (GitLab removes this file after 24 hours):

     docker compose exec gitlab cat /etc/gitlab/initial_root_password

   Browse to https://gitlab.local, sign in as root, immediately change the password,
   and configure a non-root administrator account. SSH clone URLs use port 2222.

Enable CI/CD
------------
Create a project/group runner in GitLab under Settings > CI/CD > Runners and copy
its runner authentication token (normally beginning with glrt-). Then run:

  ./scripts/register-runner.sh 'glrt-REPLACE_ME'
  docker compose --profile runner ps

The runner uses Docker's socket to create job containers. Socket access is
effectively root-equivalent; use it only for trusted lab projects. A production
installation should use an isolated runner host/VM, protected runners, restricted
tags, and no shared server socket. The runner is optional and isolated behind a
Compose profile so the GitLab server starts independently.

Minimal project .gitlab-ci.yml:

  stages: [test]
  smoke-test:
    image: alpine:3.22
    stage: test
    script:
      - echo "GitLab CI is working"

Operations
----------
Status and logs:

  docker compose ps
  docker compose logs --tail=200 gitlab
  docker compose exec gitlab gitlab-ctl status

Stop without deleting data:

  docker compose --profile runner down

Never add --volumes unless permanently destroying the installation. Start again
with docker compose up -d gitlab (and --profile runner when the runner is wanted).

Backup and restore
------------------
Run a backup before every upgrade and copy ./backups off the laptop:

  ./scripts/backup.sh

The script creates the GitLab application backup plus a timestamped archive of
gitlab-secrets.json and gitlab.rb. The secrets file is mandatory for decrypting
stored credentials. Certificates and .env should also be backed up securely.

Restore only into the exact same GitLab version. Install that version, stop Puma
and Sidekiq, place the numeric *_gitlab_backup.tar file in ./backups, and run:

  docker compose exec gitlab gitlab-ctl stop puma
  docker compose exec gitlab gitlab-ctl stop sidekiq
  docker compose exec gitlab gitlab-backup restore BACKUP=<numeric_timestamp>
  docker compose exec gitlab gitlab-ctl reconfigure
  docker compose restart gitlab
  docker compose exec gitlab gitlab-rake gitlab:check SANITIZE=true

Restore gitlab-secrets.json before the application backup when recovering to new
volumes. Consult the official restore documentation for the exact target release.
Test recovery periodically; an untested backup is not a recovery plan.

Controlled rolling upgrade
--------------------------
This single-node design cannot provide a true zero-downtime rolling upgrade. It
provides a controlled, reversible maintenance upgrade. Enterprise-style rolling
upgrades require multiple application nodes and separately managed stateful
services, which is intentionally outside this lab's scope.

1. Read the release notes and use GitLab's Upgrade Path tool. Do not skip required
   upgrade stops, and upgrade one required stop at a time. Confirm runner/server
   compatibility. Schedule downtime.
2. Verify health, make and export a backup:

     docker compose exec gitlab gitlab-rake gitlab:check SANITIZE=true
     ./scripts/backup.sh
     docker compose exec gitlab gitlab-rake gitlab:doctor:secrets

3. Edit GITLAB_VERSION in .env to an exact newer patch tag. Do not use latest.
4. Pull and recreate only GitLab:

     docker compose pull gitlab
     docker compose up -d --no-deps gitlab
     docker compose logs -f gitlab

5. Wait for healthy, then validate:

     docker compose ps
     docker compose exec gitlab gitlab-rake gitlab:check SANITIZE=true

6. Independently update GITLAB_RUNNER_VERSION to a compatible exact tag and run:

     docker compose --profile runner pull runner
     docker compose --profile runner up -d --no-deps runner

Rollback is not achieved by merely selecting an older image because database
migrations may be irreversible. Restore the pre-upgrade application/config backup
into the exact previous version instead. Keep the old image and backup until the
new release has been validated.

Future integrations
-------------------
* Jenkins: create a dedicated GitLab service account and scoped project/group
  access token, install the GitLab plugin in Jenkins, and configure webhooks.
* Gerrit: integrate through a dedicated bot and webhook/API workflow; decide which
  system is authoritative before mirroring repositories.
* Linux runners: install GitLab Runner on separate Linux VMs, trust the internal CA,
  register with tags, and use protected runners for deployment credentials.
* Container Registry: enable it only after assigning a separate registry hostname
  and certificate; avoid overloading the initial setup with another TLS endpoint.

For every integration, prefer least-privilege service accounts, expiring tokens,
protected variables, and an external secret manager. Do not store tokens in .env,
Compose YAML, Git, or CI job output.

Security and production boundary
--------------------------------
This configuration is suitable for local/internal learning, not direct exposure to
the public internet. Before production use, add organizational CA/public TLS,
firewalling, email, SSO/MFA, external PostgreSQL and object storage as scale
requires, centralized monitoring, immutable off-host backups, vulnerability
management, a tested disaster recovery plan, and isolated autoscaling runners.

Canonical references
--------------------
* Docker installation: https://docs.gitlab.com/install/docker/installation/
* Upgrade paths: https://docs.gitlab.com/update/upgrade_paths/
* Back up and restore: https://docs.gitlab.com/administration/backup_restore/
* Runner registration: https://docs.gitlab.com/runner/register/
* Docker executor security: https://docs.gitlab.com/runner/security/
