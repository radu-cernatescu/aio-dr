#!/usr/bin/env bash
# Delete the cold standby (use once the PC is back). The persistent stack is untouched.
set -euo pipefail
export AWS_PROFILE="${AWS_PROFILE:-Admin}"
# shellcheck source=common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
STACK=AioRecovery
if [ "${1:-}" != "--yes" ]; then
  read -r -p "Delete stack $STACK (EC2, VPC, DNS records)? Type 'yes': " a; [ "$a" = yes ] || exit 1
fi
aws cloudformation delete-stack --stack-name "$STACK"
aws cloudformation wait stack-delete-complete --stack-name "$STACK"
echo "$STACK deleted."
