# ADR-001: Multi-Region Resiliency and Disaster Recovery

**Status:** Accepted · **Scope:** production (`us-east-1` primary, `us-east-2` secondary, `us-west-2` ledger witness and ARC) · **Code:** `modules/ledger`, `modules/dr-routing`, `environments/production`, `app/aetherpay/ledger.py`

## Context and decision

At 02:15 UTC the primary region loses its networking and storage control planes and drops about 40% of packets. The danger is a degraded primary that keeps, or resumes, settling after failover: **split brain and double settlement**. Decision: the ledger journal is a **DynamoDB global table with Multi-Region Strong Consistency (MRSC)** (replicas in `us-east-1`/`us-east-2`, witness in `us-west-2`; a write is acknowledged only when durable in 2 of 3 regions); settlement authority belongs to **one region at a time, named in the lease item and moved only by an operator**, with a **fencing epoch** per change; everything else is **warm standby** in `us-east-2`; traffic moves with **Route 53 ARC routing controls**.

## RPO and RTO

| Data | RPO | RTO | How |
|---|---|---|---|
| Ledger journal (committed rows) | **0** | ≤ 15 min | Quorum acknowledgement: every committed row exists in 2 regions |
| Accepted, not yet journaled (regional SQS) | Not 0 | Region recovery | `202` = durable in *that region's* queue; unavailable while it is down, lost if the queue is lost. RPO 0 needs MRSC acceptance before `202` (proposed) |
| Webhook de-duplication cache, sessions | Not preserved | ≤ 5 min | Rebuilt; duplicates are harmless because journal writes are idempotent |
| Settlement workspace (Aurora Global) | ~1 s | ≤ 30 min | Promoted after traffic moves; reference workspace only (no projector or schema in this repo) |

## Active-passive vs active-active for the ledger

| | Active-passive (Aurora Global) | Active-active (DynamoDB MRSC), **chosen** |
|---|---|---|
| Replication and RPO | Async, single writer; ~1 s, unplanned failover needs `--allow-data-loss` | Synchronous 2-of-3 quorum; 0 |
| Split brain | Old writer accepts writes until externally fenced | A partitioned minority cannot reach quorum, so its writes fail |
| Cost | Local write latency, full SQL | Cross-region round trip; single-item conditional writes only |

## Fencing and quorum

- **Quorum.** A primary losing packets either reaches 2 of 3 regions (the write is linearizable everywhere) or the write fails. Two regions can never accept conflicting versions.
- **Idempotent rows.** Each event is journaled as `pk = TXN#<partner>:<event_id>` with `attribute_not_exists(pk)`. Partner and event ID are inside the webhook signature, so a replay cannot mint a new identity. Only the settler role may `PutItem` `TXN#`/`BATCH#` keys; the table policy (both replicas) denies `DeleteItem`, `BatchWriteItem` and updates to `TXN#` rows. IAM cannot force the condition itself, so append-only rests on the settler code plus IAM; administrator-proof immutability would need Streams to S3 Object Lock (proposed).
- **Lease schema.** `FENCE#settlement / LEASE` = `{region, holder, epoch, expires_at}`. `region` is the only region allowed to settle and changes only through the operator transfer (T+13), never through expiry. Every settler in every region tries to renew (same holder) or take over (expired, same region, `epoch + 1`) on each loop, so after a transfer the secondary's workers take the lease within one loop, and a recovered primary can never take it back alone. A test runs the T+13 expressions below against the code.
- **Self-fencing.** 30 s lease, timed from before the request so latency only shortens it; the holder re-reads it (strongly consistent), re-checks the time after the read, and stops under 10 s. Without quorum it cannot renew.
- **Side effects (design requirement; payment submission is not built).** A read just before a remote call cannot fence a worker paused between the two, so the payment network must enforce the batch ID as its idempotency key. Batches move `claimed → submitted → confirmed`, and a claim older than its timeout is reconciled with the network before re-submission.

## Control plane vs data plane

Failover uses only data planes or healthy-region control planes. **Traffic:** ARC `UpdateRoutingControlStates` on any of 5 regional cluster endpoints; answers come from Route 53's data plane, not `ChangeResourceRecordSets`; both ALB certificates carry the global hostname. **Credentials:** a break-glass role provisioned in the account baseline (outside this repo), assumed through regional STS in `us-east-2`; no IAM changes during the incident (IAM's control plane is in `us-east-1`). **Compute, secrets, images:** already running in `us-east-2`, with Secrets Manager replicas under a local CMK and ECR replication. **Ledger:** one conditional write moves settlement authority; the healthy majority keeps writing. **Aurora:** `failover-global-cluster` on the `us-east-2` endpoint. **Terraform:** frozen, because state lives in `us-east-1`.

## Runbook: first 30 minutes

From the offline incident vault: `ARC_EP`/`ARC_REGION` (one pair from `terraform output arc_cluster_endpoints`; on failure try the next pair), `RC_PRIMARY`/`RC_SECONDARY` (`terraform output arc_routing_control_arns`), the break-glass role ARN, `T=aetherpay-prod-ledger-journal`. Each `# gate:` must pass before the next step.

```bash
# T+0  SEV1 page; name incident commander, comms and operator; disable the terraform-apply workflow
# T+3  probe both regions + AWS Health Dashboard
for h in use1 use2; do curl -s -o /dev/null -w "$h %{http_code} %{time_total}s\n" https://$h.webhooks.example.com/healthz; done
#      gate: fail over if primary errors > 5% or p99 > 3 s for 5 min (do not wait for a full outage)
# T+5  credentials from the healthy region, installed for every later command
eval "$(aws sts assume-role --region us-east-2 --role-arn "$BREAKGLASS_ARN" --role-session-name sev1 \
  --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]' --output text \
  | awk '{print "export AWS_ACCESS_KEY_ID="$1" AWS_SECRET_ACCESS_KEY="$2" AWS_SESSION_TOKEN="$3}')"
aws sts get-caller-identity --region us-east-2                  # gate: Arn is the break-glass assumed role
# T+7  secondary readiness, then pre-scale to primary capacity
aws ecs describe-services --region us-east-2 --cluster aetherpay-prod-use2 --services aetherpay-prod-use2-ingestor aetherpay-prod-use2-settler
aws dynamodb describe-table --region us-east-2 --table-name $T --query 'Table.Replicas'   # gate: tasks healthy, replica ACTIVE
aws application-autoscaling register-scalable-target --region us-east-2 --service-namespace ecs --scalable-dimension ecs:service:DesiredCount \
  --resource-id service/aetherpay-prod-use2/aetherpay-prod-use2-ingestor --min-capacity 6 --max-capacity 60
# T+10 TRANSFER settlement authority (same expressions as app/aetherpay/ledger.py; best effort: scale the use1 settler to 0)
aws dynamodb update-item --region us-east-2 --table-name $T --return-values ALL_NEW \
  --key '{"pk":{"S":"FENCE#settlement"},"sk":{"S":"LEASE"}}' \
  --update-expression 'SET #r = :to, epoch = epoch + :one, holder = :none, expires_at = :zero' \
  --condition-expression '#r = :from' --expression-attribute-names '{"#r":"region"}' \
  --expression-attribute-values '{":to":{"S":"us-east-2"},":from":{"S":"us-east-1"},":one":{"N":"1"},":none":{"S":""},":zero":{"N":"0"}}'
#      gate: within 30 s a re-read shows region us-east-2, holder us-east-2/<task>, epoch +2; use1 settlers log "fenced" or are unreachable
# T+12 SHIFT TRAFFIC in one ARC call (the safety rule keeps at least one region On)
aws route53-recovery-cluster update-routing-control-states --region $ARC_REGION --endpoint-url $ARC_EP \
  --update-routing-control-state-entries RoutingControlArn=$RC_SECONDARY,RoutingControlState=On RoutingControlArn=$RC_PRIMARY,RoutingControlState=Off
#      gate: get-routing-control-state on the primary is Off; dig returns use2 ALB addresses within 60 s
# T+14 signed synthetic webhook through the global name (scripts/smoke-test.sh step 4), then read it back
aws dynamodb get-item --region us-east-2 --table-name $T --consistent-read --key '{"pk":{"S":"TXN#acme:evt-smoke-<ts>"},"sk":{"S":"ENTRY#0"}}'
#      gate: 202, row present with region us-east-2, queue age falling, DLQ empty, 5xx alarm OK  => ledger and traffic RTO met
# T+20 promote the Aurora workspace                               gate: writer is use2
aws rds failover-global-cluster --region us-east-2 --global-cluster-identifier aetherpay-prod-settlement \
  --target-db-cluster-identifier <use2-cluster-arn> --allow-data-loss
# T+30 ask payment networks to lift suspensions; status page; 30-min updates
#      failback only after 2 h healthy, as a planned switchover: the same transfer with :from/:to swapped, then ARC
```

## Consequences

Committed ledger rows are never lost and no two regions settle at once, without the `us-east-1` control plane. Costs: journal write latency, no multi-item MRSC transactions, the ARC cluster, paid warm standby. **Not built (reference scope):** payment submission and batch reconciliation, the journal-to-Aurora projector, MRSC acceptance before `202`, the break-glass role. Follow-ups: replicate the state bucket to `us-east-2`, quarterly FIS packet-loss game days, automate T+7 to T+14 as an ARC Region switch plan.
