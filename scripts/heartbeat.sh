#!/usr/bin/env bash
# Report liveness to CloudWatch (namespace AIO/DR). Alarms (see lib/persistent-stack.ts) email you when
#   - Heartbeat goes missing for ~20 min  -> the PC (or its network/power) is down
#   - AppsHealthy stays 0 for ~15 min     -> PC is up but AIOStreams/AIOMetadata are not answering
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$HERE/common.sh"

apps=1
curl -fsS -m 5 -o /dev/null http://127.0.0.1:80/          || apps=0   # AIOStreams
curl -fsS -m 5 -o /dev/null http://127.0.0.1:3232/health  || apps=0   # AIOMetadata
aws cloudwatch put-metric-data --namespace AIO/DR --metric-data \
  "MetricName=Heartbeat,Value=1,Unit=Count" "MetricName=AppsHealthy,Value=$apps,Unit=Count"
[ "$apps" = 1 ] || log "apps unhealthy (reported AppsHealthy=0)"
