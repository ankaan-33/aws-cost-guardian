#!/usr/bin/env bash
# The remaining optimisations, which need a human decision rather than automation.
# Usage: ./scripts/optimize.sh <lifecycle|rightsize> [region]
#   lifecycle  add the S3 rule: Standard-IA after 30 days, Glacier Flexible Retrieval after 90
#   rightsize  stop each oversized instance, change it to t3.micro, and start it again
set -euo pipefail

ACTION="${1:?Usage: optimize.sh <lifecycle|rightsize> [region]}"
REGION="${2:-$(aws configure get region)}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WASTE_STACK="costguardian-waste"

out() { aws cloudformation describe-stacks --region "$REGION" --stack-name "$WASTE_STACK" \
          --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" --output text; }

case "$ACTION" in
  lifecycle)
    BUCKET=$(out S3BucketName)
    aws s3api put-bucket-lifecycle-configuration --region "$REGION" --bucket "$BUCKET" \
      --lifecycle-configuration "file://$ROOT/policies/lifecycle.json"
    echo "Lifecycle rule added to $BUCKET"
    ;;
  rightsize)
    IDS=$(aws ec2 describe-instances --region "$REGION" \
      --filters Name=tag:Project,Values=CostGuardian Name=instance-state-name,Values=running \
      --query "Reservations[].Instances[?InstanceType!='t3.micro'].InstanceId" --output text)
    [ -n "$IDS" ] || { echo "Nothing to rightsize"; exit 0; }
    for ID in $IDS; do
      echo "==> $ID: stopping, changing to t3.micro, starting"
      aws ec2 stop-instances --region "$REGION" --instance-ids "$ID" >/dev/null
      aws ec2 wait instance-stopped --region "$REGION" --instance-ids "$ID"
      aws ec2 modify-instance-attribute --region "$REGION" --instance-id "$ID" \
        --instance-type '{"Value": "t3.micro"}'
      aws ec2 start-instances --region "$REGION" --instance-ids "$ID" >/dev/null
    done
    echo "Done. Note: CloudFormation still lists the old sizes (stack drift)."
    ;;
  *)
    echo "Unknown action: $ACTION (use lifecycle or rightsize)"; exit 1 ;;
esac
