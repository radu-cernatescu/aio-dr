#!/usr/bin/env bash
# Keep the current public IP in SSM (/aio/home-ip) so the recovery stack's security
# group allows it. Runs every few minutes from a timer on the PC; run it by hand from
# any other machine/network to allow that network too (it REPLACES the stored IP).
#
#   update-allowlist.sh            detect this machine's public IPv4
#   update-allowlist.sh 1.2.3.4    set an explicit IP
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$HERE/common.sh"

PARAM=/aio/home-ip
IP="${1:-$(curl -4 -fsS --max-time 10 https://checkip.amazonaws.com | tr -d '[:space:]')}"
[[ "$IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || die "not an IPv4 address: '$IP'"
CIDR="$IP/32"

CURRENT="$(aws ssm get-parameter --name "$PARAM" --query Parameter.Value --output text 2>/dev/null || true)"
if [ "$CURRENT" = "$CIDR" ]; then
  exit 0   # unchanged; stay quiet (timer runs often)
fi
aws ssm put-parameter --name "$PARAM" --value "$CIDR" --type String --overwrite >/dev/null
log "allowlist IP updated: ${CURRENT:-<unset>} -> $CIDR"
