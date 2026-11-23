# Cost Guardian – Automated Cloud Waste Cleanup on AWS

**AWS Well-Architected Framework: Cost Optimization Pillar**

AWS accounts quietly collect waste: oversized instances, volumes left behind when a server is terminated, Elastic IPs reserved "just in case". None of it breaks anything, so nobody notices until the bill arrives. Cost Guardian deploys a deliberately wasteful environment, detects the waste, and removes it through an automated runbook that can't delete anything until a named person approves.

```
 Wasteful environment (CloudFormation, every resource tagged Project=CostGuardian)
 ├─ 2 oversized EC2 instances (t3.small, t3.medium)      ── CPU < 1%
 ├─ 3 unattached EBS volumes (50 + 50 + 100 GiB)         ── "available"
 ├─ 2 unassociated Elastic IPs
 ├─ security group open to 0.0.0.0/0 on 22 and 80
 └─ S3 static website with no lifecycle rule

 Detect:  EC2 console audit ─ CloudWatch CPU ─ Cost Explorer (by tag) ─ Trusted Advisor
                                     │
                                     ▼
 Clean up:  Systems Manager runbook "CostGuardian-Cleanup"
            1. FindWaste        Python: tagged volumes in "available", unassociated EIPs
            2. ApproveDeletion  ──▶ SNS ──▶ email to approver  ──▶  approver IAM user approves
            3. DeleteResources  Python: delete volumes, release EIPs
            4. NotifyResult     ──▶ SNS ──▶ email report of what was removed

 Optimize:  S3 lifecycle (Standard-IA at 30 days, Glacier at 90) ─ rightsize EC2 to t3.micro
```

## What's in this repo

| Path | What it is |
|---|---|
| `infrastructure/wasteful-environment.yaml` | CloudFormation for the wasteful environment |
| `infrastructure/automation.yaml` | CloudFormation for the governance layer: SNS topic, automation role, approver policy |
| `automation/CostGuardian-Cleanup.yaml` | The Systems Manager runbook with embedded Python and an approval step |
| `policies/bucket-policy.json`, `policies/lifecycle.json` | S3 website policy and the lifecycle rule |
| `app/index.html` | Demo page hosted on S3 |
| `scripts/deploy.sh`, `scripts/run-cleanup.sh`, `scripts/optimize.sh`, `scripts/destroy.sh` | Deploy, run the cleanup, apply the remaining optimisations, and clean up |

## Design decisions

- **Human approval before anything is deleted.** The runbook finds the waste, lists every volume and Elastic IP in an email, and pauses. Nothing is removed until the approver signs in and approves, and every run is recorded in Systems Manager with who approved it.
- **Separation of duties.** The runbook runs under a service role, a different IAM user approves, and the approver can't do anything except approve or deny a run.
- **Scoped to tagged resources.** The runbook only looks at resources tagged `Project=CostGuardian`, and the role's IAM policy only allows deletes on resources carrying that tag. Untagged resources elsewhere in the account are safe even if the code is wrong.
- **Detect first, then validate.** Unattached resources are 100% waste with no business risk, so they're cleaned up straight away. Rightsizing changes a running workload, so it's a separate, deliberate step after CloudWatch confirms CPU stayed below 1%.
- **Lifecycle rules for storage.** Objects move to Standard-IA after 30 days and Glacier Flexible Retrieval after 90. S3 skips objects under 128 KB by default, because transitioning them would cost more than it saves.

## Improvements on my original console build

- **Least privilege.** In the console I attached `AmazonEC2FullAccess`, `AmazonSNSFullAccess` and `AmazonSSMFullAccess` to both the role and the approver. Here the role can only delete tagged volumes and Elastic IPs and publish to one topic, and the approver can only approve or deny.
- **Up-to-date AMI.** The original template hard-coded an Amazon Linux 2 image that only exists in one region. This version looks up the latest Amazon Linux 2023 image, so it deploys in any region.
- **Guaranteed public IPs.** Instances request a public IP themselves rather than relying on the subnet's settings.

## Results

| Waste found | Count | Monthly cost |
|---|---|---|
| Unattached EBS volumes | 3 | ~$20.00 |
| Unassociated Elastic IPs | 2 | ~$7.20 |
| Over-provisioned EC2 (t3.small/t3.medium → t3.micro) | 2 | ~$25.00 |
| **Total** | | **~$52.20** |

The runbook deleted all 3 volumes and released both Elastic IPs after approval, and the two idle instances were then terminated.

## Deploy

**You'll need:** the AWS CLI, logged in, and a default VPC in your region.

**Step 1: deploy.**

```bash
./scripts/deploy.sh <you@example.com> <region>
```

Confirm the SNS subscription email. Then attach the `ApproverPolicyArn` output to the IAM user who will approve cleanups.

**Step 2: run the cleanup.** Give it an hour or two so the CloudWatch graphs show how idle the instances are, then:

```bash
./scripts/run-cleanup.sh <approver-iam-user-arn> <region>
```

The approval email lists exactly what will be deleted. Sign in as the approver and approve the run in **Systems Manager → Automation**. A second email reports what was removed.

**Step 3: optimise what's left.**

```bash
./scripts/optimize.sh lifecycle <region>
./scripts/optimize.sh rightsize <region>
```

## Cost and clean-up

While it's running, the stack costs about **$2.70 a day**: the two instances, 200 GB of gp2 storage and four public IPv4 addresses. Since February 2024 AWS charges for every public IPv4 address, attached or not. Delete everything when you've finished:

```bash
./scripts/destroy.sh <region>
```

The IAM user you created for approvals isn't part of either stack, so delete it separately.

## Next steps

- Run the cleanup on a schedule with EventBridge Scheduler, still gated by approval
- Extend it to old snapshots, idle load balancers and stopped instances
- AWS Config rules and tag policies so untagged or oversized resources are flagged when they're created
- Budgets and Cost Anomaly Detection alerts sent to the same SNS topic
