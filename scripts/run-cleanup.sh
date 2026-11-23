#!/usr/bin/env bash
# Start the cleanup runbook. It finds tagged waste, emails an approval request,
# and waits for the approver before deleting anything.
# Usage: ./scripts/run-cleanup.sh <approver-iam-user-arn> [region]
#   e.g. ./scripts/run-cleanup.sh arn:aws:iam::123456789012:user/cost-approver us-east-1
set -euo pipefail

APPROVER="${1:?Usage: run-cleanup.sh <approver-iam-user-arn> [region]}"
REGION="${2:-$(aws configure get region)}"
GOV_STACK="costguardian-governance"

out() { aws cloudformation describe-stacks --region "$REGION" --stack-name "$GOV_STACK" \
          --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" --output text; }

EXEC_ID=$(aws ssm start-automation-execution --region "$REGION" \
  --document-name CostGuardian-Cleanup \
  --parameters "AutomationAssumeRole=$(out AutomationRoleArn),Approver=$APPROVER,NotificationTopicArn=$(out TopicArn)" \
  --query AutomationExecutionId --output text)

echo "Started execution $EXEC_ID"
echo "An approval request is on its way by email. Sign in as the approver and choose"
echo "Systems Manager > Automation > $EXEC_ID > Approve/Deny, or run:"
echo "  aws ssm send-automation-signal --automation-execution-id $EXEC_ID --signal-type Approve --region $REGION"
