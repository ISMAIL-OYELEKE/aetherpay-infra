# Staging deployment evidence

Screenshots from the staging deployment on 9 November 2026: from an empty AWS account to a working stack, through every failure found along the way, and then a full teardown. Account IDs, ARNs, key IDs and email addresses are blurred.

## 1. Bootstrap and remote state

| | |
|---|---|
| ![Bootstrap apply](01-bootstrap-apply.png) | **Bootstrap apply.** 33 resources: the encrypted state bucket, KMS keys, the GitHub OIDC roles, ECR and the workload permissions boundary. |
| ![State migration blocked](02-state-migration-blocked-by-bucket-policy.png) | **The bucket policy doing its job.** The first `terraform init -migrate-state` was refused because the lock-file write did not use the state KMS key. The policy denies any object not encrypted with that exact key. |
| ![OIDC subject diagnosis](03-oidc-immutable-subject-diagnosis.png) | **Keyless CI, first failure.** `Not authorized to perform sts:AssumeRoleWithWebIdentity`. The repository uses GitHub's immutable OIDC subject format (`repo:owner@id/name@id`), so the role trust policies were updated to match it. |

## 2. Signed plan, human approval, apply

| | |
|---|---|
| ![Signed plan comment](04-signed-plan-pr-comment.png) | **Plan on the pull request.** 203 to add, with the checksum and the Sigstore-signed artifact named in the comment. |
| ![Apply waiting](05-apply-waiting-for-approval.png) | **Apply paused at the approval gate** after verifying that the merged code is the code that was planned. |
| ![Approval comment](06-approval-issue-comment.png) | **A person approves** by commenting `approve` on the issue the pipeline opened. |
| ![Apply success](07-apply-success.png) | **Apply complete.** Every gate passed: resolve, checksum, signature, approval, apply. |

## 3. Running it, and what broke

| | |
|---|---|
| ![Image pull error](08-fargate-image-pull-error.png) | **Fargate could not start the tasks** (`mismatched image rootfs and manifest layers`). Docker 29 re-wrote the manifest on `docker tag` + `docker push`. Fixed by pushing straight from BuildKit. |
| ![Replication not authorized](09-replication-not-authorized.png) | **The settler crashed on its first write** because the ledger table's append-only policy also denied the DynamoDB replication role. Fixed by exempting that one service role. |
| ![Healthy](10-services-healthy-200.png) | **Healthy.** Ingestor 2/2, settler 1/1, both ledger replicas `ACTIVE`, `/healthz` returns 200. |
| ![Smoke test](11-smoke-test-pass.png) | **Smoke test.** TLS 1.2 refused, bad signature 401, signed webhook 202, replay 200 `duplicate`, and the WAF answering 429 after the 1,000-request burst. |
| ![Journal appended](12-ledger-journal-appended.png) | **Webhook to journal.** The settler appended the smoke-test event to the multi-region ledger journal (a journal append, not a completed payment). |
| ![Self-fencing loop](15-settler-self-fencing-loop.png) | **A subtle bug found in the logs.** A 20 s SQS long poll left exactly the 10 s lease safety margin, so the settler fenced itself on every loop. |
| ![Lease handover](16-settler-lease-handover.png) | **The fix rolling out.** The old task keeps fencing itself and then stops; the new task, which renews the lease every loop, takes over cleanly. This is a same-region rollout, not a multi-region takeover. |

## 4. Console views

| | |
|---|---|
| ![ECS services](13-console-ecs-services.png) | ECS cluster: 2 services active, 3 tasks running. |
| ![CloudWatch alarms](14-console-cloudwatch-alarms.png) | CloudWatch: alarms OK for the ALB and SQS. |
| ![WAF dashboard](17-console-waf-dashboard.png) | WAF: 3.07K requests in 3 hours, 20 blocked by the rate-based rule. |

## 5. Teardown

| | |
|---|---|
| ![Destroy complete](18-destroy-complete.png) | `terraform destroy`: 203 resources destroyed in about 14 minutes. |
| ![Teardown verified](19-teardown-verified.png) | Verified afterwards: no Aurora snapshots, no DynamoDB tables in the replica region, no ECS clusters. |
