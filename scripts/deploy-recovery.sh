#!/usr/bin/env bash
# Deploy the cold standby from the PUBLISHED template (same path as the console link). No Node/CDK.
#
#   scripts/deploy-recovery.sh                 allowlist = SSM /aio/home-ip
#   scripts/deploy-recovery.sh --my-ip         ...plus THIS machine's current public IP
#   scripts/deploy-recovery.sh 203.0.113.7/32  ...plus an explicit CIDR (only one extra is supported)
#   scripts/deploy-recovery.sh --keep ...      on failure, keep the half-built stack for debugging
#
# Tear down: scripts/destroy-recovery.sh
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export AWS_PROFILE="${AWS_PROFILE:-Admin}"
# shellcheck source=common.sh
source "$HERE/common.sh"
STACK=AioRecovery
extra=""; on_failure=ROLLBACK
for arg in "$@"; do
  case "$arg" in
    --my-ip) extra="$(curl -4 -fsS --max-time 10 https://checkip.amazonaws.com | tr -d '[:space:]')/32" ;;
    --keep)  on_failure=DO_NOTHING ;;
    *)       extra="$arg" ;;
  esac
done

outputs() { aws cloudformation describe-stacks --stack-name "$STACK" --query 'Stacks[0].Outputs[].[OutputKey,OutputValue]' --output text; }

aws sts get-caller-identity --query Arn --output text >/dev/null \
  || { echo "AWS credentials not usable. Try: aws sso login --profile $AWS_PROFILE" >&2; exit 1; }

# A previous attempt may have left the stack behind (failed create, or --keep).
status="$(aws cloudformation describe-stacks --stack-name "$STACK" --query 'Stacks[0].StackStatus' --output text 2>/dev/null || true)"
case "$status" in
  "") ;;
  CREATE_COMPLETE|UPDATE_COMPLETE)
    echo "$STACK is already running:"; outputs; exit 0 ;;
  CREATE_FAILED|ROLLBACK_COMPLETE|ROLLBACK_FAILED|DELETE_FAILED)
    echo "$STACK is left over from a failed attempt ($status) and must be deleted first."
    "$HERE/destroy-recovery.sh" ;;   # asks for confirmation
  *) echo "$STACK is busy ($status); wait for it to settle, then re-run." >&2; exit 1 ;;
esac
BUCKET="$(aws ssm get-parameter --name /aio/backup-bucket --query Parameter.Value --output text)"
URL="https://$BUCKET.s3.$AWS_REGION.amazonaws.com/dr/recovery.template.json"
HOME_IP="$(aws ssm get-parameter --name /aio/home-ip --query Parameter.Value --output text)"
[ "$extra" = "$HOME_IP" ] && extra=""   # already allowed; avoids a duplicate rule
echo "Allowlist: $HOME_IP${extra:+, $extra}"

aws cloudformation create-stack --stack-name "$STACK" --template-url "$URL" \
  --capabilities CAPABILITY_IAM --on-failure "$on_failure" \
  --parameters "ParameterKey=ExtraCidr,ParameterValue=$extra" --query StackId --output text
echo "Creating (about 10 minutes)..."
aws cloudformation wait stack-create-complete --stack-name "$STACK" || {
  echo "Stack creation failed. Recent events:" >&2
  aws cloudformation describe-stack-events --stack-name "$STACK" \
    --query "StackEvents[?contains(ResourceStatus,'FAILED')].[LogicalResourceId,ResourceStatusReason]" --output text | head -8 >&2
  exit 1; }
outputs
