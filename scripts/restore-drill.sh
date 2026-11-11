#!/usr/bin/env bash
# Prove the latest S3 backup is restorable, WITHOUT deploying anything:
# download -> verify manifest checksums -> SQLite integrity_check -> sanity-check config.
# Safe to run on any machine with docker + the aio-pc-agent (or an admin) profile.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$HERE/common.sh"
SQLITE_IMAGE="aio-dr-sqlite:1"

# Portable across GNU/Linux and macOS (no GNU-only `date -d` or `timeout` assumed).
ts_epoch() { # 20261109T120428Z -> epoch seconds
  date -u -j -f '%Y%m%dT%H%M%SZ' "$1" +%s 2>/dev/null \
    || date -u -d "$(sed -E 's/^(....)(..)(..)T(..)(..)(..)Z$/\1-\2-\3T\4:\5:\6Z/' <<<"$1")" +%s
}
with_timeout() { # <seconds> <cmd...>
  if command -v timeout >/dev/null; then timeout "$@"
  elif command -v gtimeout >/dev/null; then gtimeout "$@"
  else shift; "$@"; fi
}

BUCKET="${BUCKET:-$(aws ssm get-parameter --name /aio/backup-bucket --query Parameter.Value --output text)}"
D="$(mktemp -d)"; trap 'rm -rf "$D"' EXIT
chmod 700 "$D"

log "downloading s3://$BUCKET/backups/latest.tar.gz"
aws s3 cp --only-show-errors "s3://$BUCKET/backups/latest.tar.gz" "$D/latest.tar.gz"
tar -xzf "$D/latest.tar.gz" -C "$D"

log "verifying manifest checksums"
( cd "$D" && jq -r '.sha256 | to_entries[] | "\(.value)  \(.key)"' manifest.json | sha256sum -c --quiet - ) && log "  checksums OK"
AGE_H=$(( ( $(date -u +%s) - $(ts_epoch "$(jq -r .timestamp "$D/manifest.json")") ) / 3600 ))
log "  images: $(jq -c .images "$D/manifest.json")"
log "  backup age: ${AGE_H}h (taken on $(jq -r .host "$D/manifest.json"))"
[ "$AGE_H" -le 24 ] || log "  WARNING: newest backup is older than 24h - are the timers running?"

if ! docker image inspect "$SQLITE_IMAGE" >/dev/null 2>&1; then
  printf 'FROM alpine:3\nRUN apk add --no-cache sqlite\n' | docker build -q -t "$SQLITE_IMAGE" - >/dev/null
fi
for app in aiostreams aiometadata; do
  # Check a scratch copy inside the container: opening a WAL-mode DB read-only on a :ro mount can hang.
  res="$(with_timeout 120 docker run --rm -v "$D/$app":/d:ro "$SQLITE_IMAGE" sh -c \
    'cp /d/db.sqlite /tmp/db.sqlite && sqlite3 /tmp/db.sqlite "PRAGMA integrity_check; SELECT count(*) FROM sqlite_master;"' | paste -sd' ' -)" \
    || die "$app integrity check failed or timed out"
  log "  $app db.sqlite: $res"
  [[ "$res" == ok* ]] || die "$app database failed integrity check"
done

log "checking restored config"
for k in BASE_URL SECRET_KEY DATABASE_URI; do grep -q "^$k=" "$D/aiostreams/.env" || die "aiostreams .env missing $k"; done
for k in HOST_NAME DATABASE_URI REDIS_URL; do grep -q "^$k=" "$D/aiometadata/.env" || die "aiometadata .env missing $k"; done
[ -s "$D/aiostreams/instance-id" ] || log "  note: no aiostreams instance-id in backup"
log "restore drill PASSED"
