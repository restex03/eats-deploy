# EATS infrastructure and deployment

This repository owns production and development Docker Compose configuration. [EATS](https://github.com/restex03/employment-application-tracking-system) builds and publishes application images to GHCR.

## Fred deployment

Fred checks GHCR for a new ingestion image every five minutes after each completed check. Failed deployments trigger rollback; the most recently failed image is skipped on subsequent checks.

### 1. Install Bun (once)

On Fred, verify x86_64 and AVX2 support:

```bash
uname -m
grep -qw avx2 /proc/cpuinfo && echo "AVX2 supported"
```

For x86_64 with AVX2, install the same pinned Bun version used by CI:

```bash
(
  set -eu
  temp=$(mktemp -d)
  trap 'rm -rf "$temp"' EXIT
  cd "$temp"
  curl -fSL https://github.com/oven-sh/bun/releases/download/bun-v1.4.5/bun-linux-x64.zip -o bun-linux-x64.zip
  echo "94559b3b528995a49452f9f2404cec74f2efd7d06e0a000a8cd214b02c3666eb  bun-linux-x64.zip" | sha256sum --check
  unzip -q bun-linux-x64.zip
  sudo install -o root -g root -m 755 bun-linux-x64/bun /usr/local/bin/bun
  test "$(/usr/local/bin/bun --version)" = "1.4.5"
)
```

Without AVX2, use the baseline x64 archive; for ARM64, use the aarch64 archive. Verify the corresponding published checksum before installing.

### 2. Install the deployment script

Clone this repository on Fred and run the following commands from its root:

```bash
git clone https://github.com/restex03/eats-deploy.git
cd eats-deploy
```

Use a reviewed commit from this repository. For updates, stop the existing timer first and wait for any active deployment service to finish.

```bash
sudo install -m 644 deploy.ts /opt/eats/deploy.ts
sudo install -m 644 systemd/eats-ingestion-deploy.{service,timer} /etc/systemd/system/
sudo install -d -o eats-deploy -g eats-deploy -m 700 /opt/eats/deploy-state
sudo systemctl daemon-reload
```

Edit the existing /opt/eats/.env (leave all other settings intact):

```dotenv
INGESTION_IMAGE_REPOSITORY=ghcr.io/restex03/eats-ingestion
INGESTION_IMAGE_TAG=main
```

This repository now owns `compose.yaml` and `.env.example`. On an existing Fred deployment, keep `/opt/eats/compose.yaml` and `/opt/eats/.env`; compare and back up before applying any reviewed configuration changes. For a new deployment, copy `compose.yaml` to `/opt/eats/compose.yaml` and create `/opt/eats/.env` from `.env.example` with a strong password, the host's LAN IPv4 address and an absolute Workday sources JSON path. Provision and verify a healthy ingestion container before enabling the controller. Never overwrite an existing .env or commit secrets. The production project stays `eats` with volume `eats_postgres_data`. Both services bind to localhost and the configured LAN IP; restrict LAN access and account for Docker port forwarding in firewall rules.

Prerequisites: eats-deploy can read the local Compose configuration and .env, access Docker, and write the state directory. Ingestion must already be healthy; Docker Compose must support --wait and --wait-timeout. Docker group access is effectively root access.

```bash
sudo -u eats-deploy docker inspect --format '{{.State.Health.Status}}' eats-ingestion
docker compose version
```

### 3. Start automated deployments

Run one check manually through systemd:

```bash
sudo systemctl start eats-ingestion-deploy.service
sudo journalctl -u eats-ingestion-deploy.service -n 50 --no-pager
```

Verify successful deployment and rollback in an isolated Docker environment before enabling the timer:

```bash
sudo systemctl enable --now eats-ingestion-deploy.timer
systemctl list-timers eats-ingestion-deploy.timer
```

The timer resumes after reboot. Always use systemctl for manual deployment checks; never run the script concurrently or directly.

### 4. Monitor deployments

```bash
# Latest deployment status
systemctl status eats-ingestion-deploy.service

# Recent deployment logs (including previous failures)
sudo journalctl -u eats-ingestion-deploy.service --since today

# Watch live
sudo journalctl -fu eats-ingestion-deploy.service

# Inspect ingestion health
sudo docker inspect --format '{{.State.Health.Status}}' eats-ingestion
```

A successful oneshot service normally becomes inactive after completion.

| Log message | Meaning |
|---|---|
| Image unchanged | No deployment needed |
| Deployment verified healthy | Success |
| Rollback verified healthy | Deployment failed; previous image restored |
| Skipping quarantined image | Known failed image skipped |
| CRITICAL: Rollback failed | Manual recovery required |
| Could not persist quarantine | Stop timer and investigate |

A failed deployment returns a nonzero exit status even when rollback succeeds. Logs are not proactive alerts.

### 5. Pause deployments if recovery is needed

```bash
sudo systemctl disable --now eats-ingestion-deploy.timer
sudo journalctl -u eats-ingestion-deploy.service -n 100 --no-pager
sudo docker ps -a --filter name=eats-ingestion
sudo docker image inspect eats-ingestion:rollback-local
```

Let any active deployment finish before modifying containers or image tags. Investigate and restore ingestion if necessary, then restart the timer. Do not delete the quarantine file or rollback tag until recovery is complete. Rollback does not undo database migrations; never use docker compose down -v.

GHCR's main tag is mutable: protect publishing permissions in the EATS application repository. Require the Bun deployment unit tests and Docker Compose validation checks on this repository's main branch. Controller updates are installed manually; Fred polls images, not deployment scripts.

## Test locally

```bash
bun test --no-env-file deploy.test.ts
```

No Docker daemon or npm packages are needed.

## Local development

Clone this repo alongside EATS on your development machine. Docker Compose 2.24.4+ is required for the development override. From this repository root:

```bash
cp -n .env.dev.example .env
# Edit .env: set WORKDAY_SOURCES_HOST_PATH to the absolute path
# of the EATS apps/web/data/JobSources/workdaySources.json file.
bash infrastart.sh
```

If you have an existing EATS development `deploy/.env`, copy it here instead of creating a new one, without overwriting any existing .env. Keep the development DB password consistent with your existing PostgreSQL role. The override uses project `eats-dev`, database `eats`, container `eats-postgres`, named volume `eats-postgres-data`, and localhost-only bindings. No data migration is needed. If an old unmanaged container conflicts with Compose, stop ingestion and remove only that development container; keep the volume.

To run containerized ingestion instead of `dotnet run`, build the matching local image in EATS using `bash deployScripts/build-ingestion.sh 0.1.21` (or your configured tag). From this repo:

```bash
docker compose -f compose.yaml -f compose.dev.yaml --env-file .env up -d
```

Do not run both ingestion processes against the same database. Stop development containers without deleting data:

```bash
docker compose -f compose.yaml -f compose.dev.yaml --env-file .env down
```

Use the override for every development Compose invocation. Never use the production stack on your development machine by accident. For a deliberate **development-only** database reset, stop ingestion, run the preceding down command, then `docker volume rm eats-postgres-data` and `bash infrastart.sh`. This permanently deletes development PostgreSQL data.

## Validate Compose

```bash
docker compose --env-file .env -f compose.yaml -f compose.dev.yaml config --quiet
```

On Fred, use only the production file: `docker compose --env-file .env config --quiet`. Do not share expanded Compose configuration; it may contain secrets.
