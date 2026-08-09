# GitLab Docker Compose Lab

A reproducible GitLab Community Edition lab with HTTPS, persistent storage, backups, monitoring, and an optional Docker executor runner.

This project is designed for internal development, testing, and learning on macOS with OrbStack, while keeping the deployment close to a small enterprise environment without unnecessary infrastructure.

### Where to start

| Task | Use this section |
| --- | --- |
| First installation | [5. Build and Start from Scratch](#5-build-and-start-from-scratch) |
| Normal start and stop | [6. Daily Operations](#6-daily-operations) |
| Enable CI/CD | [8. Enable CI/CD](#8-enable-cicd) |
| Back up or restore GitLab | [10. Backup and Restore](#10-backup-and-restore) |
| Upgrade GitLab | [11. Controlled Upgrade](#11-controlled-upgrade) |
| Verify a running stack | [13. Acceptance Checklist](#13-acceptance-checklist) |
| Diagnose a failure | [14. Troubleshooting](#14-troubleshooting) |

## Features

* Pinned GitLab Community Edition image
* HTTPS with a locally generated or organization-issued certificate
* Git over SSH on a dedicated host port
* Persistent GitLab configuration, logs, application data, and runner state
* Built-in Prometheus monitoring
* Container health checks
* Optional GitLab Runner with the Docker executor
* Application and configuration backup helper
* Explicit `linux/amd64` compatibility for OrbStack on Apple Silicon
* Version pinning and a controlled upgrade workflow

---

## 1. Architecture

```text
Browser / Git client
    |
    | HTTPS 443 / SSH 2222
    v
GitLab CE (Omnibus)
    |
    +-- NGINX
    +-- Puma and Sidekiq
    +-- PostgreSQL
    +-- Redis
    +-- Gitaly
    +-- Prometheus
    |
    +-- gitlab-config volume
    +-- gitlab-logs volume
    +-- gitlab-data volume
    +-- ./backups

Optional GitLab Runner
    |
    +-- Docker executor
    +-- runner-config volume
    +-- /var/run/docker.sock
```

GitLab Omnibus owns the application and its supporting services inside one persistent server container. This resembles a small enterprise installation while intentionally avoiding an external database, object storage, load balancer, or Kubernetes.

The runner is isolated behind a Compose profile, so GitLab can run independently. For a production deployment, runners should be placed on separate hosts or virtual machines.

---

## 2. Edition and Version Strategy

GitLab Community Edition is recommended for this permanent personal lab. CE is free to use and includes repositories, merge requests, the container registry, and CI/CD.

The GitLab EE image can run without a paid license and exposes the Free tier, but it does not add a required capability for this project. A future migration to EE should follow GitLab's supported CE-to-EE procedure and change the image only at a supported version boundary.

The server version is pinned in `.env` rather than using `latest`. Pinning makes deployments reproducible and upgrades deliberate. Always review the current GitLab release notes and required upgrade stops before changing the version.

---

## 3. Repository Structure

```text
.
├── .env.example
├── .gitignore
├── docker-compose.yml
├── README.md
├── scripts/
│   ├── backup.sh
│   ├── generate-certificate.sh
│   └── register-runner.sh
└── secrets/
    └── ssl/
        └── .gitkeep
```

Generated local files such as `.env`, TLS certificates, private keys, and backup archives must not be committed.

---

## 4. Prerequisites

Recommended environment:

* macOS with OrbStack and Docker compatibility enabled
* Docker Compose v2
* Git
* OpenSSL
* At least 8 GB RAM allocated to the container runtime
* At least 4 CPU cores and 20 GB of free disk space

Check the required tools:

```bash
docker version
docker compose version
git --version
openssl version
```

Check that the default ports are available:

```bash
lsof -nP -iTCP:80 -sTCP:LISTEN || true
lsof -nP -iTCP:443 -sTCP:LISTEN || true
lsof -nP -iTCP:2222 -sTCP:LISTEN || true
```

GitLab's server image is published for `linux/amd64`. The Compose file explicitly selects that platform, so an Apple Silicon Mac runs it through OrbStack emulation. The first start can be slow, and its performance should not be treated as production performance.

---

## 5. Build and Start from Scratch

### 5.1 Clone and configure

```bash
git clone <this-repository-url>
cd gitlab-docker
cp .env.example .env
```

Default configuration:

```env
GITLAB_VERSION=18.3.6-ce.0
GITLAB_HOSTNAME=gitlab.local
GITLAB_HTTPS_PORT=443
GITLAB_SSH_PORT=2222
GITLAB_TIMEZONE=UTC
GITLAB_RUNNER_VERSION=alpine-v18.3.1
```

Keep `GITLAB_HTTPS_PORT` at `443` for the simplest URL. If the port conflicts with another local service, update it in `.env` and include the new port in the browser URL.

### 5.2 Configure local name resolution

Check first, then add the entry only if it is missing:

```bash
grep -E '^[[:space:]]*127\.0\.0\.1[[:space:]]+.*gitlab\.local([[:space:]]|$)' /etc/hosts \
  || echo '127.0.0.1 gitlab.local' | sudo tee -a /etc/hosts
```

Verify resolution:

```bash
ping -c 1 gitlab.local
```

If `GITLAB_HOSTNAME` is changed, use the same hostname in `/etc/hosts` and regenerate the certificate.

### 5.3 Generate and trust the TLS certificate

Generate a self-signed certificate for the local lab:

```bash
./scripts/generate-certificate.sh
```

Trust it in the macOS system keychain:

```bash
sudo security add-trusted-cert -d -r trustRoot \
  -k /Library/Keychains/System.keychain \
  secrets/ssl/gitlab.local.crt
```

For shared internal use, replace the generated certificate and key with files issued by the organization's certificate authority. Their basename must match `GITLAB_HOSTNAME`, for example:

```text
secrets/ssl/gitlab.example.internal.crt
secrets/ssl/gitlab.example.internal.key
```

The private key must be unencrypted so GitLab NGINX can read it during startup. Never commit private keys. For an internet-accessible deployment, prefer public DNS, an edge reverse proxy, and an ACME-issued certificate.

### 5.4 Validate and start GitLab

```bash
docker compose config --quiet
docker compose pull gitlab
docker compose up -d gitlab
docker compose ps
```

Initialization commonly takes several minutes. Follow the startup logs:

```bash
docker compose logs -f gitlab
```

Wait until `docker compose ps` reports the service as healthy.

### 5.5 Complete initial sign-in

Retrieve the one-time root password. GitLab removes this file after 24 hours:

```bash
docker compose exec gitlab cat /etc/gitlab/initial_root_password
```

Open [https://gitlab.local](https://gitlab.local), sign in as `root`, and immediately change the password. Create a separate non-root administrator account for routine administration.

SSH clone URLs use port `2222` by default:

```bash
git clone ssh://git@gitlab.local:2222/group/project.git
```

---

## 6. Daily Operations

Start GitLab without the optional runner:

```bash
docker compose up -d gitlab
```

Start GitLab and the registered runner:

```bash
docker compose --profile runner up -d
```

Check status and logs:

```bash
docker compose ps
docker compose logs --tail=200 gitlab
docker compose exec gitlab gitlab-ctl status
```

Stop all services while preserving data:

```bash
docker compose --profile runner down
```

Do not add `--volumes` unless the installation is being permanently destroyed. Named volumes contain GitLab configuration, repositories, database data, logs, and runner configuration.

---

## 7. HTTPS and SSH Verification

Check the HTTPS endpoint:

```bash
curl --fail --show-error --head https://gitlab.local/users/sign_in
```

Inspect the certificate when troubleshooting trust or hostname problems:

```bash
openssl s_client -connect gitlab.local:443 -servername gitlab.local </dev/null
```

Check the SSH endpoint:

```bash
ssh -T -p 2222 git@gitlab.local
```

An unauthenticated SSH check may report that access is denied. That is expected until a public key is added to the GitLab user profile.

---

## 8. Enable CI/CD

Create a project or group runner in GitLab under **Settings > CI/CD > Runners**, then copy its runner authentication token. Modern runner tokens normally begin with `glrt-`.

Register and start the runner:

```bash
./scripts/register-runner.sh 'glrt-REPLACE_ME'
docker compose --profile runner ps
```

The registration is persisted in the `runner-config` volume. Do not store runner tokens in `.env`, Compose YAML, Git, shell history, or CI job output.

The runner uses the Docker socket to create job containers. Docker socket access is effectively root-equivalent on the host. Use this runner only for trusted lab projects. A production environment should use isolated runner hosts, protected runners, restricted tags, and no shared server socket.

### 8.1 Minimal pipeline example

Create `.gitlab-ci.yml` in a test project:

```yaml
stages:
  - test

smoke-test:
  image: alpine:3.22
  stage: test
  script:
    - echo "GitLab CI is working"
```

Commit and push the file, then confirm the job succeeds under **Build > Pipelines**.

---

## 9. Monitoring and Health

GitLab's built-in Prometheus monitoring is enabled by the Omnibus configuration. Use the following commands for routine health checks:

```bash
docker compose ps
docker inspect --format '{{json .State.Health}}' gitlab-lab-gitlab-1
docker compose exec gitlab gitlab-rake gitlab:check SANITIZE=true
docker compose exec gitlab gitlab-rake gitlab:doctor:secrets
```

The exact container name can vary. Find it with:

```bash
docker compose ps --format json
```

For a long-lived shared installation, export metrics and logs to external monitoring instead of relying only on data inside the GitLab container.

---

## 10. Backup and Restore

### 10.1 Create a backup

Run a backup before every upgrade:

```bash
./scripts/backup.sh
```

The script creates:

* A GitLab application backup in `./backups`
* A timestamped archive containing `gitlab-secrets.json` and `gitlab.rb`

The secrets file is mandatory for decrypting stored credentials. Back up `.env` and the TLS files separately and securely. Copy all backups off the laptop; a backup stored only beside the running system is not a disaster recovery plan.

### 10.2 Restore GitLab

Restore an application backup only into the exact same GitLab version that created it.

1. Set `GITLAB_VERSION` to the original exact version and start GitLab.
2. Restore `gitlab-secrets.json` and `gitlab.rb` when recovering onto new volumes.
3. Place the numeric `*_gitlab_backup.tar` file in `./backups`.
4. Stop the application processes and restore the backup:

```bash
docker compose exec gitlab gitlab-ctl stop puma
docker compose exec gitlab gitlab-ctl stop sidekiq
docker compose exec gitlab gitlab-backup restore BACKUP=<numeric_timestamp>
docker compose exec gitlab gitlab-ctl reconfigure
docker compose restart gitlab
docker compose exec gitlab gitlab-rake gitlab:check SANITIZE=true
```

Consult the official restore documentation for the exact target release. Test recovery periodically; an untested backup is not a recovery plan.

---

## 11. Controlled Upgrade

This single-node design cannot provide a true zero-downtime rolling upgrade. It provides a controlled and reversible maintenance upgrade. Enterprise-style rolling upgrades require multiple application nodes and separately managed stateful services, which are intentionally outside this lab's scope.

### 11.1 Prepare

1. Read the release notes and use GitLab's Upgrade Path tool.
2. Identify every required upgrade stop; never jump directly across required stops.
3. Confirm runner and server compatibility.
4. Schedule downtime.
5. Verify health and create a backup:

```bash
docker compose exec gitlab gitlab-rake gitlab:check SANITIZE=true
docker compose exec gitlab gitlab-rake gitlab:doctor:secrets
./scripts/backup.sh
```

### 11.2 Upgrade GitLab

Edit `GITLAB_VERSION` in `.env` to the next exact supported patch tag. Never use `latest`.

```bash
docker compose pull gitlab
docker compose up -d --no-deps gitlab
docker compose logs -f gitlab
```

Wait for the service to become healthy, then validate it:

```bash
docker compose ps
docker compose exec gitlab gitlab-rake gitlab:check SANITIZE=true
docker compose exec gitlab gitlab-rake gitlab:doctor:secrets
```

Repeat this process separately for each required upgrade stop.

### 11.3 Upgrade GitLab Runner

Update `GITLAB_RUNNER_VERSION` in `.env` to a compatible exact tag:

```bash
docker compose --profile runner pull runner
docker compose --profile runner up -d --no-deps runner
docker compose --profile runner ps
```

### 11.4 Roll back safely

Do not roll back by selecting an older image against an upgraded database. Database migrations may be irreversible.

Restore the pre-upgrade application and configuration backups into the exact previous GitLab version. Keep the old image and all backups until the new release has passed the acceptance checklist.

---

## 12. Future Integrations

### Jenkins

Create a dedicated GitLab service account and a scoped project or group access token. Install the GitLab plugin in Jenkins and configure project webhooks. Keep GitLab as the repository authority and Jenkins as an external CI orchestrator.

### Gerrit

Use a dedicated bot account and a webhook or API workflow. Decide whether GitLab or Gerrit is authoritative before configuring repository mirroring.

### Linux runners

Install GitLab Runner on separate Linux virtual machines, trust the internal certificate authority, register runners with clear tags, and use protected runners for jobs that access deployment credentials.

### Container Registry

Enable the registry after assigning a separate registry hostname and certificate. Treat it as a second TLS endpoint and define its storage, backup, retention, and authentication policies before enabling it.

For every integration, prefer least-privilege service accounts, expiring tokens, protected variables, and an external secret manager.

---

## 13. Acceptance Checklist

After installation or an upgrade, verify all of the following:

```bash
docker compose config --quiet
docker compose ps
docker compose exec gitlab gitlab-ctl status
docker compose exec gitlab gitlab-rake gitlab:check SANITIZE=true
curl --fail --show-error --head https://gitlab.local/users/sign_in
```

Also verify manually:

* The browser trusts the HTTPS certificate.
* An administrator can sign in.
* A test project can be created.
* HTTPS clone, commit, push, and pull succeed.
* SSH clone and push succeed on port `2222`.
* A test CI pipeline completes on the runner, when enabled.
* A fresh backup completes and is copied off-host.

---

## 14. Troubleshooting

### GitLab remains unhealthy during first start

The first Omnibus configuration can take several minutes, especially under `amd64` emulation on Apple Silicon.

```bash
docker compose logs --tail=300 gitlab
docker compose exec gitlab gitlab-ctl status
docker stats --no-stream
```

Confirm that the container runtime has at least 8 GB RAM and sufficient free disk space.

### HTTPS certificate errors

Confirm that the configured hostname matches the certificate basename and subject alternative name:

```bash
grep '^GITLAB_HOSTNAME=' .env
ls -l secrets/ssl
openssl x509 -in secrets/ssl/gitlab.local.crt -noout -subject -ext subjectAltName
```

Regenerate the certificate after changing the hostname, then recreate GitLab:

```bash
./scripts/generate-certificate.sh
docker compose up -d --no-deps --force-recreate gitlab
```

### A host port is already in use

```bash
lsof -nP -iTCP:80 -sTCP:LISTEN
lsof -nP -iTCP:443 -sTCP:LISTEN
lsof -nP -iTCP:2222 -sTCP:LISTEN
```

Stop the conflicting service or update the corresponding value in `.env`. If HTTPS is moved, use the configured port in URLs.

### Runner cannot connect to GitLab

```bash
docker compose --profile runner logs --tail=200 runner
docker compose exec runner gitlab-runner verify
docker compose exec runner ls -l /etc/gitlab-runner/certs
```

Confirm that the runner certificate matches `GITLAB_HOSTNAME` and that the runner is attached to the `gitlab-lab_gitlab` network.

### CI job cannot start Docker containers

```bash
docker compose exec runner ls -l /var/run/docker.sock
docker compose exec runner gitlab-runner list
```

Confirm that the Docker socket exists in the host runtime. Remember that exposing this socket gives jobs powerful host access; do not weaken its permissions as a shortcut.

---

## 15. Security and Production Boundary

This configuration is suitable for local or internal learning. It must not be exposed directly to the public internet without additional controls.

Before production use, add:

* Organization-issued or public TLS certificates
* Firewalling and network segmentation
* SMTP email delivery
* SSO and enforced MFA
* External PostgreSQL and object storage when scale requires them
* Centralized monitoring and log retention
* Immutable off-host backups
* Vulnerability and patch management
* A tested disaster recovery plan
* Isolated and optionally autoscaling runners

Never store tokens, passwords, or private keys in `.env`, Compose YAML, Git, or CI job output.

---

## 16. Canonical References

* [Install GitLab in a Docker container](https://docs.gitlab.com/install/docker/installation/)
* [GitLab upgrade paths](https://docs.gitlab.com/update/upgrade_paths/)
* [Back up and restore GitLab](https://docs.gitlab.com/administration/backup_restore/)
* [Register GitLab Runner](https://docs.gitlab.com/runner/register/)
* [GitLab Runner security](https://docs.gitlab.com/runner/security/)

---

## License

See [LICENSE](LICENSE).
