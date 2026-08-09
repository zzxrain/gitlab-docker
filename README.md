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
* HTTPS through the shared Jenkins Caddy ingress and local CA
* Git over SSH on a dedicated host port
* Persistent GitLab configuration, logs, application data, and runner state
* Built-in Prometheus monitoring
* Container health checks
* Optional GitLab Runner with the Docker executor
* Application and configuration backup helper
* Native multi-architecture images for Apple Silicon and x86-64 hosts
* Local-only port binding by default
* Bounded Docker stdout/stderr log retention
* Version pinning and a controlled upgrade workflow

---

## 1. Architecture

```text
Browser / Git client
    |
    | HTTPS 8445
    v
Jenkins Caddy
    |
    | HTTP 80 over local-tooling-edge
    v
GitLab CE (Omnibus) <--- SSH 2222 --- Git client
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
    +-- $HOME/DevTools/Backup/gitlab-docker

Optional GitLab Runner
    |
    +-- Docker executor
    +-- runner-config volume
    +-- Caddy local root CA (trust only)
    +-- /var/run/docker.sock (Runner daemon only)
```

GitLab Omnibus owns the application and its supporting services inside one persistent server container. This resembles a small enterprise installation while intentionally avoiding an external database, object storage, load balancer, or Kubernetes.

The Jenkins Caddy container is the shared local TLS ingress: port `8444` routes to Jenkins and port `8445` routes to GitLab. Caddy keeps its CA private key in the Jenkins `caddy_data` volume and automatically manages both leaf certificates. GitLab serves HTTP only on the external `local-tooling-edge` Docker network and never receives the CA private key.

The runner is isolated behind a Compose profile, so GitLab can run without a local runner. For a production deployment, runners should be placed on separate hosts or virtual machines.

---

## 2. Edition and Version Strategy

GitLab Community Edition is recommended for this permanent personal lab. CE is free to use and includes repositories, merge requests, the container registry, and CI/CD.

The GitLab EE image can run without a paid license and exposes the Free tier, but it does not add a required capability for this project. A future migration to EE should follow GitLab's supported CE-to-EE procedure and change the image only at a supported version boundary.

The server version is pinned in `.env` rather than using `latest`. Pinning makes deployments reproducible and upgrades deliberate. The committed default is GitLab `19.2.1-ce.0`; always review the current maintenance policy, release notes, and required upgrade stops before changing it.

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
│   ├── ensure-shared-network.sh
│   └── register-runner.sh
```

Generated local files such as `.env` and backup archives must not be committed. The Caddy root certificate is exported and maintained by the sibling Jenkins repository; its private key must remain in the Jenkins Caddy data volume.

---

## 4. Prerequisites

Recommended environment:

* macOS with OrbStack and Docker compatibility enabled
* Docker Compose v2
* Git
* OpenSSL
* The sibling `jenkins-docker` repository with its Caddy root exported to `certs/caddy-local-root.crt`
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
lsof -nP -iTCP:8445 -sTCP:LISTEN || true
lsof -nP -iTCP:2222 -sTCP:LISTEN || true
```

The pinned GitLab and Runner images publish both `linux/arm64` and `linux/amd64` variants. Compose does not force a platform, so Docker selects the native image for an Apple Silicon or x86-64 host. The first start can still be slow because GitLab must initialize and configure all bundled services.

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
GITLAB_VERSION=19.2.1-ce.0
GITLAB_HOSTNAME=apps.localmac.net
GITLAB_BIND_ADDRESS=127.0.0.1
GITLAB_HTTPS_PORT=8445
GITLAB_SSH_PORT=2222
GITLAB_TIMEZONE=Asia/Shanghai
GITLAB_BACKUP_DIR=${HOME}/DevTools/Backup/gitlab-docker
CADDY_ROOT_CA_PATH=../jenkins-docker/certs/caddy-local-root.crt
TOOLING_EDGE_NETWORK=local-tooling-edge
GITLAB_RUNNER_VERSION=alpine-v19.2.1
DOCKER_LOG_MAX_SIZE=50m
DOCKER_LOG_MAX_FILES=5
```

The default browser URL is `https://apps.localmac.net:8445`. The Jenkins Caddy Compose project binds HTTPS to `127.0.0.1`; this GitLab project uses `GITLAB_BIND_ADDRESS` only for SSH port `2222`. Change either binding deliberately only when LAN access is required and protected by an appropriate firewall.

### 5.2 Configure local name resolution

Check first, then add the entry only if it is missing:

```bash
grep -E '^[[:space:]]*127\.0\.0\.1[[:space:]]+.*apps\.localmac\.net([[:space:]]|$)' /etc/hosts \
  || echo '127.0.0.1 apps.localmac.net' | sudo tee -a /etc/hosts
```

Verify resolution:

```bash
ping -c 1 apps.localmac.net
```

If `GITLAB_HOSTNAME` is changed, use the same hostname in `/etc/hosts` and in the Jenkins Caddyfile so Caddy can issue the correct leaf certificate.

### 5.3 Prepare the shared Caddy ingress

Confirm that the exported Caddy root exists:

```bash
test -f ../jenkins-docker/certs/caddy-local-root.crt
openssl x509 -in ../jenkins-docker/certs/caddy-local-root.crt \
  -noout -subject -issuer -dates -fingerprint -sha256
```

Trust this root once if it is not already present in the macOS system keychain:

```bash
sudo security add-trusted-cert -d -r trustRoot \
  -k /Library/Keychains/System.keychain \
  ../jenkins-docker/certs/caddy-local-root.crt
```

Create the shared external network and recreate the Jenkins Caddy service so it listens on both HTTPS ports:

```bash
./scripts/ensure-shared-network.sh

cd ../jenkins-docker
docker compose config --quiet
docker compose up -d --no-deps caddy
docker compose ps caddy
cd ../gitlab-docker
```

Caddy stores and rotates its root, intermediate, leaf certificates, and private keys in the Jenkins `caddy_data` volume. Do not copy the root private key into this repository or delete that volume during routine maintenance.

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

Wait until `docker compose ps` reports the service as healthy. GitLab does not publish its web port directly; Caddy reaches port `80` through `local-tooling-edge` and publishes HTTPS on host port `8445`.

### 5.5 Complete initial sign-in

Retrieve the one-time root password. GitLab removes this file after 24 hours:

```bash
docker compose exec gitlab cat /etc/gitlab/initial_root_password
```

Open [https://apps.localmac.net:8445](https://apps.localmac.net:8445), sign in as `root`, and immediately change the password. Create a separate non-root administrator account for routine administration.

SSH clone URLs use port `2222` by default:

```bash
git clone ssh://git@apps.localmac.net:2222/group/project.git
```

---

## 6. Daily Operations

GitLab and the optional Runner use a manual restart policy. They do not start
automatically when Docker or OrbStack starts; start them only when the lab is
needed.

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

Stop all services while preserving their containers and data:

```bash
docker compose --profile runner stop
```

Remove the stopped service containers while preserving their data when needed:

```bash
docker compose --profile runner down
```

Neither command stops the shared Jenkins Caddy service. Do not add `--volumes` unless the installation is being permanently destroyed. Named volumes contain GitLab configuration, repositories, database data, logs, and runner configuration.

---

## 7. HTTPS and SSH Verification

Check the HTTPS endpoint:

```bash
curl --cacert ../jenkins-docker/certs/caddy-local-root.crt \
  --fail --show-error --head \
  https://apps.localmac.net:8445/users/sign_in
```

Inspect the certificate when troubleshooting trust or hostname problems:

```bash
openssl s_client -connect apps.localmac.net:8445 -servername apps.localmac.net </dev/null
```

Check the SSH endpoint:

```bash
ssh -T -p 2222 git@apps.localmac.net
```

An unauthenticated SSH check may report that access is denied. That is expected until a public key is added to the GitLab user profile.

---

## 8. Enable CI/CD

Create a project or group runner in GitLab under **Settings > CI/CD > Runners**, then copy its runner authentication token. Modern runner tokens normally begin with `glrt-`.

Register and start the runner:

```bash
./scripts/register-runner.sh
docker compose --profile runner ps
```

The script prompts for the token without echoing it, which keeps it out of shell history. Registration is persisted in the `runner-config` volume. Do not store runner tokens in `.env`, Compose YAML, Git, or CI job output.

The Runner daemon uses the Docker socket to create job containers on `local-tooling-edge`, allowing the helper container to resolve the shared Caddy endpoint. The socket is not mounted into job containers by default. Docker socket access remains effectively root-equivalent for the Runner daemon itself. Use it only for trusted lab projects. Jobs that must build container images should use a separate protected runner and an isolated builder such as rootless BuildKit or carefully secured Docker-in-Docker.

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
docker inspect --format '{{json .State.Health}}' "$(docker compose ps -q gitlab)"
docker compose exec gitlab gitlab-rake gitlab:check SANITIZE=true
docker compose exec gitlab gitlab-rake gitlab:doctor:secrets
```

The exact container name can vary. Find it with:

```bash
docker compose ps --format json
```

For a long-lived shared installation, export metrics and logs to external monitoring instead of relying only on data inside the GitLab container.

Compose also rotates each container's Docker `json-file` output at 50 MB and keeps five files by default. Adjust `DOCKER_LOG_MAX_SIZE` and `DOCKER_LOG_MAX_FILES` in `.env` when required. This is independent of GitLab's internal log rotation under `/var/log/gitlab`.

---

## 10. Backup and Restore

### 10.1 Create a backup

Run a backup before every upgrade:

```bash
./scripts/backup.sh
```

The script creates:

* A GitLab application backup in `$HOME/DevTools/Backup/gitlab-docker`
* A timestamped configuration archive containing `gitlab-secrets.json`, `gitlab.rb`, `.env`, `docker-compose.yml`, and the public Caddy root certificate when available
* A SHA-256 checksum file covering the application and configuration backups

On this macOS host, the default destination resolves to `/Users/pandahorn/DevTools/Backup/gitlab-docker`. Override `GITLAB_BACKUP_DIR` in `.env` when another external location is required. The secrets file is mandatory for decrypting stored credentials. Configuration archives contain private material and are created with restrictive permissions. Copy the backups and checksum file to encrypted off-host storage; a backup stored only on the same machine is not a disaster recovery plan.

### 10.2 Restore GitLab

Restore an application backup only into the exact same GitLab version that created it.

1. Set `GITLAB_VERSION` to the original exact version and start GitLab.
2. Restore `gitlab-secrets.json` and `gitlab.rb` when recovering onto new volumes.
3. Place the numeric `*_gitlab_backup.tar` file in `$GITLAB_BACKUP_DIR`.
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
curl --cacert ../jenkins-docker/certs/caddy-local-root.crt \
  --fail --show-error --head \
  https://apps.localmac.net:8445/users/sign_in
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

The first Omnibus configuration can take several minutes while GitLab initializes all bundled services.

```bash
docker compose logs --tail=300 gitlab
docker compose exec gitlab gitlab-ctl status
docker stats --no-stream
```

Confirm that the container runtime has at least 8 GB RAM and sufficient free disk space.

### HTTPS or Caddy errors

Confirm that the exported root matches the root currently persisted by Caddy:

```bash
openssl x509 -in ../jenkins-docker/certs/caddy-local-root.crt \
  -noout -subject -issuer -dates -fingerprint -sha256

cd ../jenkins-docker
docker compose logs --tail=200 caddy
```

Confirm that Caddy and GitLab share the external network and that Caddy can resolve the GitLab alias:

```bash
docker network inspect local-tooling-edge
docker compose exec caddy wget -qO- http://gitlab/-/readiness
```

Do not delete `caddy_data` as a first repair step. Doing so replaces the trusted local CA. Re-export and re-trust the root only after an intentional CA reset.

### A host port is already in use

```bash
lsof -nP -iTCP:8445 -sTCP:LISTEN
lsof -nP -iTCP:2222 -sTCP:LISTEN
```

Port `8445` belongs to the Jenkins Caddy container, while `2222` belongs to GitLab. Stop the conflicting service or update both the relevant Compose/Caddy configuration and documented URL.

### Runner cannot connect to GitLab

```bash
docker compose --profile runner logs --tail=200 runner
docker compose exec runner gitlab-runner verify
docker compose exec runner ls -l /etc/gitlab-runner/certs
```

Confirm that the Runner mounts the exported Caddy root as `apps.localmac.net.crt` and is attached to both `gitlab-docker_gitlab` and `local-tooling-edge`.

### CI job cannot start Docker containers

```bash
docker compose exec runner ls -l /var/run/docker.sock
docker compose exec runner gitlab-runner list
```

Confirm that the Docker socket exists in the host runtime for the Runner daemon. It is intentionally absent from ordinary job containers. Use a separate protected image-building runner instead of weakening socket permissions or adding the socket to every job.

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
