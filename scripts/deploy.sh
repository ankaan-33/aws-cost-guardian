#!/usr/bin/env bash
# Deploy the wasteful environment and the governance layer, publish the website,
# and register the cleanup runbook.
# Usage: ./scripts/deploy.sh <alert-email> [region]
#   e.g. ./scripts/deploy.sh me@example.com us-east-1
set -euo pipefail

EMAIL="${1:?Usage: deploy.sh <alert-email> [region]}"
REGION="${2:-$(aws configure get region)}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WASTE_STACK="costguardian-waste"
GOV_STACK="costguardian-governance"
DOC="CostGuardian-Cleanup"

echo "==> Finding the default VPC and two subnets in different AZs"
VPC=$(aws ec2 describe-vpcs --region "$REGION" --filters Name=isDefault,Values=true \
  --query "Vpcs[0].VpcId" --output text)
[ "$VPC" != "None" ] || { echo "No default VPC in $REGION"; exit 1; }
# us-east-1e doesn't offer t3 instances, so skip it
read -r SUBNET1 SUBNET2 < <(aws ec2 describe-subnets --region "$REGION" \
  --filters Name=vpc-id,Values="$VPC" Name=default-for-az,Values=true \
  --query "Subnets[?AvailabilityZone!='us-east-1e'] | sort_by(@,&AvailabilityZone)[:2].SubnetId" \
  --output text)

echo "==> Deploying the wasteful environment"
aws cloudformation deploy --region "$REGION" --stack-name "$WASTE_STACK" \
  --template-file "$ROOT/infrastructure/wasteful-environment.yaml" \
  --parameter-overrides VpcId="$VPC" SubnetId="$SUBNET1" SubnetId2="$SUBNET2"

echo "==> Deploying the governance layer (SNS, automation role, approver policy)"
aws cloudformation deploy --region "$REGION" --stack-name "$GOV_STACK" \
  --template-file "$ROOT/infrastructure/automation.yaml" \
  --capabilities CAPABILITY_IAM \
  --parameter-overrides AlertEmail="$EMAIL"

out() { aws cloudformation describe-stacks --region "$REGION" --stack-name "$1" \
          --query "Stacks[0].Outputs[?OutputKey=='$2'].OutputValue" --output text; }

BUCKET=$(out "$WASTE_STACK" S3BucketName)
echo "==> Publishing the website to $BUCKET"
sed "s/BUCKET_NAME/$BUCKET/" "$ROOT/policies/bucket-policy.json" > /tmp/costguardian-bucket-policy.json
aws s3api put-bucket-policy --region "$REGION" --bucket "$BUCKET" \
  --policy file:///tmp/costguardian-bucket-policy.json
aws s3 cp "$ROOT/app/index.html" "s3://$BUCKET/index.html" --region "$REGION" --content-type text/html

echo "==> Registering the $DOC runbook"
if aws ssm describe-document --region "$REGION" --name "$DOC" >/dev/null 2>&1; then
  aws ssm update-document --region "$REGION" --name "$DOC" --document-version '$LATEST' \
    --document-format YAML --content "file://$ROOT/automation/CostGuardian-Cleanup.yaml" >/dev/null || true
else
  aws ssm create-document --region "$REGION" --name "$DOC" --document-type Automation \
    --document-format YAML --content "file://$ROOT/automation/CostGuardian-Cleanup.yaml" \
    --tags Key=Project,Value=CostGuardian >/dev/null
fi

aws cloudformation describe-stacks --region "$REGION" --stack-name "$WASTE_STACK" \
  --query "Stacks[0].Outputs" --output table
aws cloudformation describe-stacks --region "$REGION" --stack-name "$GOV_STACK" \
  --query "Stacks[0].Outputs" --output table
echo "Confirm the SNS subscription email, then attach ApproverPolicyArn to your approver IAM user."
