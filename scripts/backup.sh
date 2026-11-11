#!/usr/bin/env bash
# Snapshot AIOStreams + AIOMetadata state and upload it to the S3 backup bucket.
#
#   backup.sh                 normal run (snapshot -> upload)
#   DRY_RUN=1 backup.sh DIR   build the archive into DIR, do not upload
#
# What is backed up (everything needed to recreate the deployment "exactly"):
#   - consistent SQLite snapshots of both databases (taken with sqlite3 .backup)
#   - both .env files and both compose files
#   - AIOStreams instance-id
#   - manifest.json (timestamps, checksums, image digests)
# Caches (mapping files, anime DBs, Redis) are NOT backed up; apps re-download them.
set -euo pipefail
umask 077
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$HERE/common.sh"

AIOSTREAMS_DIR="${AIOSTREAMS_DIR:-$HOME/aiostreams}"
AIOMETADATA_DIR="${AIOMETADATA_DIR:-$HOME/aiometadata}"
# aiometadata/compose.yaml mounts ${DOCKER_DATA_DIR}/aiometadata/data. DOCKER_DATA_DIR is UNSET
# locally, so that expands to /aiometadata/data (and /aiometadata/cache for Redis).
AIOSTREAMS_DATA="${AIOSTREAMS_DATA:-$AIOSTREAMS_DIR/data}"
AIOMETADATA_DATA="${AIOMETADATA_DATA:-/aiometadata/data}"
SQLITE_IMAGE="aio-dr-sqlite:1"
DRY_RUN="${DRY_RUN:-0}"

exec 9>"${XDG_RUNTIME_DIR:-/tmp}/aio-dr-backup.lock"
flock -n 9 || die "another backup is already running"

for f in "$AIOSTREAMS_DIR/.env" "$AIOSTREAMS_DIR/compose.yaml" "$AIOSTREAMS_DATA/db.sqlite" \
         "$AIOMETADATA_DIR/.env" "$AIOMETADATA_DIR/compose.yaml" "$AIOMETADATA_DATA/db.sqlite"; do
  [ -r "$f" ] || die "missing or unreadable: $f"
done

# Tiny local image that just provides sqlite3 (databases are root-owned, WAL-mode).
if ! docker image inspect "$SQLITE_IMAGE" >/dev/null 2>&1; then
  log "building $SQLITE_IMAGE"
  printf 'FROM alpine:3\nRUN apk add --no-cache sqlite\n' | docker build -q -t "$SQLITE_IMAGE" - >/dev/null
fi

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
TS="$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$STAGE/aiostreams" "$STAGE/aiometadata"

snapshot_db() { # <src data dir> <dest dir>
  docker run --rm -e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)" \
    -v "$1":/src -v "$2":/out "$SQLITE_IMAGE" sh -euc '
      sqlite3 /src/db.sqlite ".backup /out/db.sqlite"
      [ "$(sqlite3 /out/db.sqlite "PRAGMA integrity_check;")" = "ok" ] || { echo "integrity_check failed" >&2; exit 1; }
      chown "$HOST_UID:$HOST_GID" /out/db.sqlite'
}

log "snapshotting databases"
snapshot_db "$AIOSTREAMS_DATA"  "$STAGE/aiostreams"
snapshot_db "$AIOMETADATA_DATA" "$STAGE/aiometadata"

cp "$AIOSTREAMS_DIR/.env" "$AIOSTREAMS_DIR/compose.yaml" "$STAGE/aiostreams/"
[ -r "$AIOSTREAMS_DATA/instance-id" ] && cp "$AIOSTREAMS_DATA/instance-id" "$STAGE/aiostreams/"
cp "$AIOMETADATA_DIR/.env" "$AIOMETADATA_DIR/compose.yaml" "$STAGE/aiometadata/"

# Digest of the image the RUNNING container uses (the local :latest tag can be newer if it was pulled but
# the container not recreated). Falls back to the tag, then "unknown". The recovery bootstrap pins to these.
digest() { # <compose dir> <service> <fallback image tag>
  local cid img="$3"
  cid="$(docker compose -f "$1/compose.yaml" ps -q "$2" 2>/dev/null | head -1 || true)"
  [ -n "$cid" ] && img="$(docker inspect --format '{{.Image}}' "$cid" 2>/dev/null || echo "$3")"
  docker image inspect "$img" --format '{{index .RepoDigests 0}}' 2>/dev/null || echo "unknown"
}
(
  cd "$STAGE"
  jq -n \
    --arg ts "$TS" --arg host "$(hostname)" --arg amdata "$AIOMETADATA_DATA" \
    --arg as_img "$(digest "$AIOSTREAMS_DIR" aiostreams ghcr.io/viren070/aiostreams:latest)" \
    --arg am_img "$(digest "$AIOMETADATA_DIR" aiometadata ghcr.io/cedya77/aiometadata:latest)" \
    --argjson sums "$(find aiostreams aiometadata -type f -print0 | xargs -0 sha256sum | jq -R 'split("  ") | {(.[1]): .[0]}' | jq -s add)" \
    '{timestamp:$ts, host:$host, aiometadata_data_path:$amdata, docker_data_dir:"", images:{aiostreams:$as_img, aiometadata:$am_img}, sha256:$sums}' \
    > manifest.json
)

ARCHIVE="$STAGE/aio-$TS.tar.gz"
tar -C "$STAGE" -czf "$ARCHIVE" manifest.json aiostreams aiometadata
SIZE="$(du -h "$ARCHIVE" | cut -f1)"

if [ "$DRY_RUN" = "1" ]; then
  OUT="${1:?DRY_RUN needs an output directory}"
  mkdir -p "$OUT"; cp "$ARCHIVE" "$OUT/"
  log "dry run: wrote $OUT/aio-$TS.tar.gz ($SIZE)"
  exit 0
fi

BUCKET="${BUCKET:-$(aws ssm get-parameter --name /aio/backup-bucket --query Parameter.Value --output text)}"
[ -n "$BUCKET" ] || die "could not determine backup bucket"

# One key, overwritten each run. Bucket versioning retains history; a lifecycle rule keeps the current
# version plus the 1 newest previous one (see lib/persistent-stack.ts). No timestamped keys accumulate.
log "uploading backup ($SIZE, taken $TS) to s3://$BUCKET/backups/latest.tar.gz"
aws s3 cp --only-show-errors "$ARCHIVE" "s3://$BUCKET/backups/latest.tar.gz"
# Success marker for the aio-backup-stale alarm (lib/persistent-stack.ts). Non-fatal: if this fails the
# alarm fires, which is the right outcome.
aws cloudwatch put-metric-data --namespace AIO/DR --metric-data "MetricName=BackupSucceeded,Value=1,Unit=Count" \
  || log "WARNING: could not report BackupSucceeded; the aio-backup-stale alarm will fire"
log "done"
