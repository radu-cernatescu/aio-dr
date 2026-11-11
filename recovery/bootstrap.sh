# Instance bootstrap (runs as root via EC2 user-data on Amazon Linux 2023, x86_64).
# Expects BACKUP_BUCKET, ZONE_ID, STREAMS_HOST, META_HOST, COMPOSE_VERSION, COMPOSE_SHA256 (exported by the
# CDK-generated preamble, which also writes /opt/aio/caddy/Dockerfile). Third-party artifacts come from S3 (staged by scripts/publish-template.sh) with
# the public internet as a fallback: GitHub release downloads were observed to 504 repeatedly from EC2.
# Pasted into user-data verbatim, so keep it self-contained and under ~10 KB.

export HOME=/root   # cloud-init user-data runs without HOME; docker/aws tooling expects it

# Everything below talks to the internet (GitHub, ghcr.io, Docker Hub, S3): retry transient failures.
retry() { local n=0; until "$@"; do n=$((n+1)); [ "$n" -ge 5 ] && return 1; echo "retry $n/5: $*" >&2; sleep $((n*5)); done; }

# 2 GiB swap: the Caddy (Go) build plus both apps would otherwise be tight on a 2 GiB instance.
if ! swapon --show | grep -q .; then
  fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap /swapfile >/dev/null && swapon /swapfile
fi

REGION="$(retry curl -fsS -X PUT http://169.254.169.254/latest/api/token -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' \
  | xargs -I{} curl -fsS -H 'X-aws-ec2-metadata-token: {}' http://169.254.169.254/latest/meta-data/placement/region)"
export AWS_DEFAULT_REGION="$REGION" AWS_REGION="$REGION"

# ---- Docker + pinned compose plugin (checksum verified) ---------------------------------------
retry dnf install -y docker jq tar
systemctl enable --now docker
PLUGINS=/usr/local/lib/docker/cli-plugins
ART="s3://$BACKUP_BUCKET/dr/artifacts"
mkdir -p "$PLUGINS"
retry aws s3 cp --only-show-errors "$ART/docker-compose-$COMPOSE_VERSION" "$PLUGINS/docker-compose" \
  || { echo "compose not in S3; falling back to GitHub" >&2
       for i in 1 2 3 4 5 6 7 8; do curl -fsSL -o "$PLUGINS/docker-compose" \
         "https://github.com/docker/compose/releases/download/$COMPOSE_VERSION/docker-compose-linux-x86_64" && break; sleep $((i*8)); done; }
echo "$COMPOSE_SHA256  $PLUGINS/docker-compose" | sha256sum -c -
chmod +x "$PLUGINS/docker-compose"
docker compose version

# ---- Restore the latest backup ------------------------------------------------------------------
WORK=/opt/aio
mkdir -p "$WORK/restore"
retry aws s3 cp "s3://$BACKUP_BUCKET/backups/latest.tar.gz" "$WORK/latest.tar.gz" --only-show-errors
tar -xzf "$WORK/latest.tar.gz" -C "$WORK/restore"
# Verify every file against the manifest before using it.
( cd "$WORK/restore" && jq -r '.sha256 | to_entries[] | "\(.value)  \(.key)"' manifest.json | sha256sum -c - )
jq '{timestamp, host, images}' "$WORK/restore/manifest.json"

# AIOStreams: ./data relative to its compose dir.
mkdir -p "$WORK/aiostreams/data"
cp "$WORK/restore/aiostreams/.env" "$WORK/restore/aiostreams/compose.yaml" "$WORK/aiostreams/"
cp "$WORK/restore/aiostreams/db.sqlite" "$WORK/aiostreams/data/"
[ -f "$WORK/restore/aiostreams/instance-id" ] && cp "$WORK/restore/aiostreams/instance-id" "$WORK/aiostreams/data/"

# AIOMetadata: compose mounts ${DOCKER_DATA_DIR}/aiometadata/{data,cache}; DOCKER_DATA_DIR is empty
# locally, so the real paths are /aiometadata/data and /aiometadata/cache. Redis runs as uid 999.
mkdir -p "$WORK/aiometadata" /aiometadata/data /aiometadata/cache
cp "$WORK/restore/aiometadata/.env" "$WORK/restore/aiometadata/compose.yaml" "$WORK/aiometadata/"
cp "$WORK/restore/aiometadata/db.sqlite" /aiometadata/data/
chown -R 999 /aiometadata/cache

# Public URLs change from the LAN address to the HTTPS hostnames. Nothing else in .env is touched
# (SECRET_KEY etc. stay identical so stored configs still decrypt).
sed -i "s|^BASE_URL=.*|BASE_URL=https://$STREAMS_HOST|" "$WORK/aiostreams/.env"
sed -i "s|^HOST_NAME=.*|HOST_NAME=https://$META_HOST|" "$WORK/aiometadata/.env"

# Publish app ports on loopback only (Caddy on the host network is the sole public entry point), and pin
# each app to the image digest the PC was running when the backup was taken (manifest.json), so the
# restored database is never opened by a newer, untested release. No usable digest -> the compose tag.
port() { case "$1" in aiostreams) echo 3000 ;; aiometadata) echo 3232 ;; esac; }
write_override() { # <app> <pin: 1|0>
  local img=""
  [ "$2" = 1 ] && img="$(jq -r --arg a "$1" '.images[$a] // ""' "$WORK/restore/manifest.json")"
  case "$img" in *@sha256:*) ;; *) img="" ;; esac
  {
    printf 'services:\n  %s:\n' "$1"
    [ -n "$img" ] && printf '    image: %s\n' "$img"
    printf '    ports: !override\n      - "127.0.0.1:%s:%s"\n' "$(port "$1")" "$(port "$1")"
  } > "$WORK/$1/compose.override.yaml"
  echo "$1 image: ${img:-<compose tag>}"
}
for app in aiostreams aiometadata; do write_override "$app" 1; done

# ---- Caddy with Route53 DNS-01 (credentials come from the instance role via IMDS) ---------------
mkdir -p "$WORK/caddy/data" "$WORK/caddy/config"
if retry aws s3 cp --only-show-errors "$ART/caddy-route53.tar.gz" "$WORK/caddy.tar.gz" && docker load -i "$WORK/caddy.tar.gz"; then
  echo "loaded prebuilt caddy image from S3"
else
  echo "prebuilt caddy not available; building (slow)" >&2
  # $WORK/caddy/Dockerfile is written by the CDK preamble from recovery/caddy/Dockerfile.
  ( cd "$WORK/caddy" && retry docker build -t aio-caddy:1 . )
fi
cat > "$WORK/caddy/Caddyfile" <<EOF
# wait_for_route53_sync: wait until Route53 reports the TXT record in sync BEFORE asking Let's Encrypt to
# validate; without it its multi-region validators can see NXDOMAIN and the cert silently fails.
(route53_tls) {
	tls {
		dns route53 {
			region $REGION
			hosted_zone_id $ZONE_ID
			wait_for_route53_sync true
		}
	}
}
$STREAMS_HOST {
	import route53_tls
	reverse_proxy 127.0.0.1:$(port aiostreams)
}
$META_HOST {
	import route53_tls
	reverse_proxy 127.0.0.1:$(port aiometadata)
}
EOF
cat > "$WORK/caddy/compose.yaml" <<EOF
services:
  caddy:
    image: aio-caddy:1
    restart: unless-stopped
    network_mode: host
    environment:
      - AWS_REGION=$REGION
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - ./data:/data
      - ./config:/config
EOF

# ---- Start everything ---------------------------------------------------------------------------
export DOCKER_DATA_DIR=""
# The Caddy image is already loaded/built above; pull the app images, then start. If a pinned digest
# can no longer be pulled, fall back to the compose tag rather than failing the recovery.
for app in aiostreams aiometadata; do
  if ! ( cd "$WORK/$app" && retry docker compose pull ); then
    echo "pulling the pinned $app image failed; falling back to the compose tag" >&2
    write_override "$app" 0
    ( cd "$WORK/$app" && retry docker compose pull )
  fi
done
( cd "$WORK/aiostreams"  && docker compose up -d )
( cd "$WORK/aiometadata" && docker compose up -d )
( cd "$WORK/caddy"       && docker compose up -d )

# Wait for the apps (loopback; a fresh instance has no caches, so first start can be slow) so that
# cfn-signal reports a real success. Up to 10 minutes (the stack allows 20 for the whole bootstrap).
healthy=0
for i in $(seq 1 120); do
  if curl -fsS -o /dev/null http://127.0.0.1:3000/ && curl -fsS -o /dev/null http://127.0.0.1:3232/health; then healthy=1; break; fi
  sleep 5
done
if [ "$healthy" != 1 ]; then
  docker ps -a; docker compose -f "$WORK/aiostreams/compose.yaml" logs --tail 40 || true
  docker compose -f "$WORK/aiometadata/compose.yaml" logs --tail 40 || true
  echo "apps did not become healthy" >&2; exit 1
fi
echo "aio bootstrap complete"
