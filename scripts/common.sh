# shellcheck shell=bash
# Shared config for aio-dr scripts. Override anything in ~/.config/aio-dr/config.env
log() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

CONFIG_FILE="${AIO_DR_CONFIG:-$HOME/.config/aio-dr/config.env}"
# shellcheck disable=SC1090
[ -f "$CONFIG_FILE" ] && source "$CONFIG_FILE"

export AWS_PROFILE="${AWS_PROFILE:-aio-pc-agent}"
export AWS_PAGER=""

# Region: $AWS_REGION, else "region" in aio.config.json (repo root, gitignored), else the profile's region.
AIO_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AWS_REGION="${AWS_REGION:-$(jq -r '.region // empty' "$AIO_REPO/aio.config.json" 2>/dev/null || true)}"
AWS_REGION="${AWS_REGION:-$(aws configure get region 2>/dev/null || true)}"
[ -n "$AWS_REGION" ] || die "no AWS region: set AWS_REGION, \"region\" in aio.config.json, or the $AWS_PROFILE profile's region"
export AWS_REGION AWS_DEFAULT_REGION="$AWS_REGION"
