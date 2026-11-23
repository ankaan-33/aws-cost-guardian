#!/usr/bin/env bash
# Empty the website bucket (CloudFormation can't delete a non-empty bucket),
# then delete both stacks and the runbook.
# Usage: ./scripts/destroy.sh [region]
set -euo pipefail
REGION="${1:-$(aws configure get region)}"
WASTE_STACK="costguardian-waste"
GOV_STACK="costguardian-governance"

BUCKET=$(aws cloudformation describe-stacks --region "$REGION" --stack-name "$WASTE_STACK" \
  --query "Stacks[0].Outputs[?OutputKey=='S3BucketName'].OutputValue" --output text 2>/dev/null || true)
if [ -n "$BUCKET" ] && [ "$BUCKET" != "None" ]; then
  aws s3 rm "s3://$BUCKET" --recursive --region "$REGION"
fi

for STACK in "$WASTE_STACK" "$GOV_STACK"; do
  aws cloudformation delete-stack --region "$REGION" --stack-name "$STACK"
  aws cloudformation wait stack-delete-complete --region "$REGION" --stack-name "$STACK"
  echo "Deleted $STACK"
done

aws ssm delete-document --region "$REGION" --name CostGuardian-Cleanup 2>/dev/null \
  && echo "Deleted CostGuardian-Cleanup runbook" || true
