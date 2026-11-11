# aio-dr

Disaster recovery for the local AIOStreams + AIOMetadata deployment.

## Layout

| Path | Purpose |
|---|---|
| `lib/persistent-stack.ts` | S3 backup bucket, Route53 zone for your delegated subdomain, IAM user `aio-pc-agent`, SSM discovery params, SNS email topic + PC-down / apps-down / backup-stale alarms |
| `scripts/heartbeat.sh` | Every 5 min: puts `Heartbeat` and `AppsHealthy` metrics (namespace `AIO/DR`) |
| `recovery/caddy/Dockerfile` | Caddy + Route53 DNS plugin; prebuilt and staged in S3, also the on-instance fallback recipe |
| `scripts/publish-template.sh` | Synthesizes `AioRecovery` and publishes the standalone template + `RUNBOOK.txt` to `s3://<bucket>/dr/` |
| `scripts/destroy-recovery.sh` | Deletes the `AioRecovery` stack |
| `scripts/backup.sh` | Consistent SQLite snapshots + `.env` + compose files -> S3 |
| `scripts/update-allowlist.sh` | Writes current public IP to SSM `/aio/home-ip` (dynamic-IP allowlist) |
| `lib/recovery-stack.ts` + `recovery/bootstrap.sh` | Cold standby: VPC, EC2 (t3a.small), 443-only allowlisted SG, Caddy + Route53 DNS-01 TLS, A records |
| `scripts/deploy-recovery.sh` | One command to bring the standby up from the published template (no Node/CDK needed) |
| `scripts/restore-drill.sh` | Verifies the latest S3 backup is restorable (no AWS resources created; runs on Linux or macOS) |
| `scripts/install-agent.sh` | Installs the systemd user timers (backup every 6h, IP sync and heartbeat every 5 min) |
| `aio.config.json` | **Your** settings: `region`, `domain`, `alertEmail` (gitignored; copy `aio.config.example.json`). Optional: `streamsHost`, `metaHost` (default `streams.`/`meta.` + domain), `instanceType` |

Requires Node 20+ (`nvm use 24`) for CDK. Deploying/publishing uses the `Admin` profile
(`aws sso login --profile Admin`); the PC timers use the narrow `aio-pc-agent` profile.

## One-time setup (in order)

1. **Config:** `cp aio.config.example.json aio.config.json` and fill in your region, the subdomain to
   delegate to Route53 (e.g. `aio.example.com`) and the alert email. The scripts read `region` from it too
   (or from `AWS_REGION` / the profile's region).
2. **AWS credentials:** an admin-capable SSO profile (`Admin`) for deploying.
3. **Bootstrap + deploy** (once):
   ```bash
   nvm use 24
   npx cdk bootstrap            # first time in this account/region
   npx cdk deploy AioPersistent
   ```
4. **Delegate the subdomain** at the parent domain's DNS provider: copy the four values from the
   `NameServers` output and add them as **NS records** for the subdomain's host. Verify:
   `dig NS <your domain> +short`
5. **Create the agent's access key** and store it as a profile (secret is shown once):
   ```bash
   aws iam create-access-key --user-name aio-pc-agent
   aws configure --profile aio-pc-agent        # same region as aio.config.json
   ```
6. **Seed the allowlist and first backup, then start the timers:**
   ```bash
   scripts/update-allowlist.sh
   scripts/backup.sh
   scripts/install-agent.sh
   ```

## Dynamic IP / allowlist

The recovery security group allows the IP stored in SSM `/aio/home-ip` (parameter `AllowedCidr`, resolved at
deploy time) plus one optional `ExtraCidr`. The SSM parameter is deliberately **not** managed by
CloudFormation so redeploying never resets it. The PC refreshes it every 5 minutes. To allow the network
you are on during an outage, pass `--my-ip` (or an explicit CIDR) to `scripts/deploy-recovery.sh`.

## Alerts

`scripts/heartbeat.sh` reports every 5 minutes. Email alarms (SNS topic, subscription must be confirmed once):
- `aio-pc-silent`: no heartbeat for ~20 min -> PC/power/network down. Deploy the recovery stack.
- `aio-apps-unhealthy`: PC up but AIOStreams/AIOMetadata not answering for ~15 min.
- `aio-backup-stale`: no successful backup (`BackupSucceeded` metric from `scripts/backup.sh`) for 13h,
  i.e. two missed runs. Also fires while the PC is down. Check `journalctl --user -u aio-backup`.

Alarm-only: nothing auto-deploys.

## Backup contents / restore notes

`s3://<bucket>/backups/latest.tar.gz`, overwritten on every run. Bucket versioning keeps history and
a lifecycle rule keeps the current version plus the 1 newest previous one (older versions are deleted
after >= 1 day). Older versions: `aws s3api list-object-versions --bucket <bucket> --prefix backups/`
(admin only; the backup agent cannot list or delete versions). Archive layout:

```
manifest.json   timestamps, sha256 of every file, image digests
aiostreams/     compose.yaml  .env  db.sqlite  instance-id
aiometadata/    compose.yaml  .env  db.sqlite
```

- `AIOStreams` `SECRET_KEY` (in `.env`) must be unchanged on restore or stored configs
  will not decrypt - restoring the `.env` from the same archive guarantees this.
- `aiometadata/compose.yaml` mounts `${DOCKER_DATA_DIR}/aiometadata/data`. `DOCKER_DATA_DIR` is
  unset locally, so the real paths are `/aiometadata/data` and `/aiometadata/cache`. The
  recovery stack restores with `DOCKER_DATA_DIR` empty to land on the same paths.
- Both images are `amd64` only as far as is verified locally: use x86 instances (`t3a`/`t3`),
  not Graviton (`t4g`), unless multi-arch is confirmed.
- Caches (mapping files, anime DBs, Redis) are not backed up; apps rebuild them.
- Compose files use `:latest`, but the manifest records the digest of the image each running container
  uses, and the recovery bootstrap pins to those, so the restored DB runs on the same app version. If a
  pinned digest cannot be pulled, it falls back to the compose tag (logged in the bootstrap log).

## Disaster recovery runbook (PC is down)

The recovery template is standalone and lives in S3, so no repo, Node or CDK is needed.

**From the AWS console** (works from any device): sign in first, then open the link in
`s3://<bucket>/dr/RUNBOOK.txt` (also printed by `scripts/publish-template.sh`), tick the IAM
acknowledgement, optionally set `ExtraCidr` to your current network, and create the stack.

**From a shell with this repo and an admin profile** (`aws sso login --profile Admin`):
```bash
scripts/deploy-recovery.sh --my-ip      # --my-ip also allowlists the network you are on right now
```

Takes ~10 min (it waits for the instance to restore the backup and start the apps).
Outputs the two URLs: `https://streams.<domain>` and `https://meta.<domain>`.
Shell access (no SSH, no open ports): the `ShellCommand` output, an `aws ssm start-session ...`.
Bootstrap log on the instance: `/var/log/aio-bootstrap.log`.

When the PC is back: `scripts/destroy-recovery.sh` (or delete the `AioRecovery` stack in the console).
The persistent stack stays.

Re-publish the template with `scripts/publish-template.sh` whenever the recovery stack or bootstrap changes.

Notes:
- URLs change vs. the local LAN address: Stremio addons must be (re)installed with the new
  HTTPS URLs. Only `BASE_URL` / `HOST_NAME` are rewritten on restore; everything else (including
  `SECRET_KEY`) is restored unchanged.
- Debugging a failed bootstrap: stack creation rolls back on failure and deletes the instance. Use
  `scripts/deploy-recovery.sh --keep` to keep it for inspection (then `scripts/destroy-recovery.sh`).
  Re-running `deploy-recovery.sh` detects a leftover failed stack and offers to delete it first.
- Let's Encrypt: each fresh deploy requests new certs (limit: 5 duplicate certs/week per hostname).
- The app ports are bound to 127.0.0.1; Caddy (host network) is the only public entry point and the only
  thing that can reach the instance role (IMDSv2, hop limit 1).
- The repo holds no personal data or secrets; `aio.config.json` (gitignored) is the only local piece.
  Keep a copy of it off the PC so the CDK stacks can be redeployed if the PC dies. The published template
  in S3 does not need it.
