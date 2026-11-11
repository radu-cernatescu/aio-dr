#!/usr/bin/env bash
# Synthesize the recovery stack and publish its (standalone) CloudFormation template to S3 so it can
# be deployed WITHOUT this repo, Node, or CDK: from the console link or scripts/deploy-recovery.sh.
# Re-run whenever lib/recovery-stack.ts or recovery/bootstrap.sh change. Needs admin credentials.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
export AWS_PROFILE="${AWS_PROFILE:-Admin}"
# shellcheck source=common.sh
source scripts/common.sh
# shellcheck disable=SC1090
[ -s "$HOME/.nvm/nvm.sh" ] && { source "$HOME/.nvm/nvm.sh"; nvm use 24 >/dev/null 2>&1 || true; }

BUCKET="$(aws ssm get-parameter --name /aio/backup-bucket --query Parameter.Value --output text)"
KEY="dr/recovery.template.json"
URL="https://$BUCKET.s3.$AWS_REGION.amazonaws.com/$KEY"

# --- Stage third-party artifacts in S3 so recovery does not depend on GitHub / Go module downloads ---
# shellcheck disable=SC1091
source recovery/versions.env
ART="s3://$BUCKET/dr/artifacts"
if ! aws s3 ls "$ART/docker-compose-$COMPOSE_VERSION" >/dev/null 2>&1; then
  echo "staging docker compose $COMPOSE_VERSION..."
  tmp="$(mktemp)"
  curl --retry 8 --retry-all-errors --retry-delay 3 -fsSL -o "$tmp" \
    "https://github.com/docker/compose/releases/download/$COMPOSE_VERSION/docker-compose-linux-x86_64"
  echo "$COMPOSE_SHA256  $tmp" | sha256sum -c - >/dev/null
  aws s3 cp --only-show-errors "$tmp" "$ART/docker-compose-$COMPOSE_VERSION"; rm -f "$tmp"
fi
if ! aws s3 ls "$ART/caddy-route53.tar.gz" >/dev/null 2>&1 || [ "${REBUILD_CADDY:-0}" = 1 ]; then
  echo "building + staging caddy (route53) image (a few minutes the first time)..."
  docker build -q -t aio-caddy:1 recovery/caddy >/dev/null
  tmp="$(mktemp)"; docker save aio-caddy:1 | gzip > "$tmp"
  aws s3 cp --only-show-errors "$tmp" "$ART/caddy-route53.tar.gz"; rm -f "$tmp"
fi

echo "synthesizing..."
npx cdk synth AioRecovery --quiet >/dev/null
T="cdk.out/AioRecovery.template.json"
[ -s "$T" ] || { echo "synth produced no template" >&2; exit 1; }
# Standalone check: the only asset may be the template itself.
[ "$(jq '.files | length' cdk.out/AioRecovery.assets.json)" = "1" ] || { echo "template has extra assets; not standalone" >&2; exit 1; }

aws s3 cp --only-show-errors "$T" "s3://$BUCKET/$KEY"
# Validate through the S3 URL: proves CloudFormation can read the private object with *your* credentials.
aws cloudformation validate-template --template-url "$URL" --query 'Parameters[].ParameterKey' --output text >/dev/null
echo "published + validated: $URL"

# Documented "quick-create" format (lands on the review page). The template URL needs no encoding;
# leaving it plain keeps the link short and survives terminal wrapping / copy-paste.
STREAMS_URL="$(jq -r '.Outputs.StreamsUrl.Value' "$T")"
META_URL="$(jq -r '.Outputs.MetaUrl.Value' "$T")"
LINK="https://$AWS_REGION.console.aws.amazon.com/cloudformation/home?region=$AWS_REGION#/stacks/create/review?templateURL=$URL&stackName=AioRecovery"

cat > "$(dirname "$T")/RUNBOOK.txt" <<RB
AIO disaster recovery - PC is down
===================================
1. Sign in to AWS FIRST (IAM Identity Center portal -> account -> Management console), region $AWS_REGION.
   Opening the link while signed out can drop the part after "#", landing you on the console home.
2. Then open this link (or paste the template URL below into Create stack -> Amazon S3 URL),
   tick the IAM acknowledgement, and click Create stack:

   $LINK

   Optional: put the network you are on right now in "ExtraCidr" (e.g. 203.0.113.7/32).
   "AllowedCidr" defaults to your PC's last known IP (SSM /aio/home-ip).
3. Wait ~10 minutes (stack status CREATE_COMPLETE). URLs are in the stack Outputs:
   $STREAMS_URL  and  $META_URL
   (Reinstall the Stremio addons with these HTTPS URLs.)
4. When your PC is back: delete the AioRecovery stack in the console. Backups continue meanwhile.

Template URL (plain, for the console's "Amazon S3 URL" field - no quotes/spaces):
   $URL

CLI alternative (no repo needed):
   aws cloudformation create-stack --stack-name AioRecovery --region $AWS_REGION \\
     --template-url $URL --capabilities CAPABILITY_IAM \\
     --parameters ParameterKey=ExtraCidr,ParameterValue=<your.ip>/32
   aws cloudformation wait stack-create-complete --stack-name AioRecovery
RB
aws s3 cp --only-show-errors "$(dirname "$T")/RUNBOOK.txt" "s3://$BUCKET/dr/RUNBOOK.txt"
echo; echo "Console link (bookmark this; also saved as s3://$BUCKET/dr/RUNBOOK.txt):"; echo "$LINK"
