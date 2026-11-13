# ADR-001: Multi-Region Resiliency and Disaster Recovery

**Status:** Accepted · **Scope:** production (`us-east-1` primary, `us-east-2` secondary, `us-west-2` ledger witness and ARC) · **Code:** `modules/ledger`, `modules/dr-routing`, `environments/production`

## Context and decision

At 02:15 UTC the primary region loses its networking and storage control planes and drops about 40% of packets: degraded, not dead. The real danger is a degraded primary that keeps, or later resumes, settling after failover, causing **split-brain writes and double settlement**. Decision: the ledger journal is a **DynamoDB global table with Multi-Region Strong Consistency (MRSC)** (replicas in `us-east-1`/`us-east-2`, witness in `us-west-2`; a write is acknowledged only when durable in 2 of 3 regions); settlement has **one writer, enforced by a fencing epoch**; everything else is **warm standby** in `us-east-2`; traffic moves with **Route 53 ARC routing controls**.

## RPO and RTO

| Data | RPO | RTO | How |
|---|---|---|---|
| Ledger journal (immutable) | **0** | ≤ 15 min | Quorum acknowledgement: every acknowledged entry exists in 2 regions |
| Settlement workspace (Aurora) | ≤ 1 s lag, financially 0 | ≤ 15 min | Aurora Global failover; any lost tail is replayed from the journal |
| Unsettled events (SQS) | 0 once acknowledged | ≤ 15 min | `202` only after a durable enqueue; partners retry; the ledger de-duplicates |
| Webhook de-duplication cache, sessions | Not preserved | ≤ 5 min | Rebuilt; duplicates are harmless because ledger writes are idempotent |

## Active-passive vs active-active for the ledger

| | Active-passive (Aurora Global) | Active-active (DynamoDB MRSC), **chosen** |
|---|---|---|
| Replication and RPO | Async, single writer; ~1 s, unplanned failover needs `--allow-data-loss` | Synchronous 2-of-3 quorum; 0 |
| Split brain | Old writer accepts writes until externally fenced | A partitioned minority cannot reach quorum, so its writes fail |
| Cost | Local write latency, full SQL | Cross-region round trip; single-item conditional writes only |

Aurora stays as the batching and reporting workspace; sub-second RPO is fine there because it is rebuilt from the journal.

## Fencing and quorum

- **Quorum.** A primary losing packets either reaches 2 of 3 regions (the write is linearizable everywhere) or the write fails. Two regions can never accept conflicting versions.
- **Idempotent rows.** Each settlement is `pk = TXN#<settlement_id>` written with `attribute_not_exists(pk)`, where the ID is the rail's idempotency key. A second write from any region fails, so double-recording is impossible.
- **Fencing epoch for external side effects.** The lease item `FENCE#settlement` holds `{epoch, holder, expires_at}` and is taken by a conditional update that increments the epoch. A batch is claimed with `PutItem BATCH#<id>` carrying the epoch; right before calling the payment network the worker re-reads the lease (strongly consistent) and aborts unless the epoch is still its own. The batch ID is the network's idempotency key. IAM restricts settlers to `FENCE#*`/`BATCH#*` keys (`dynamodb:LeadingKeys`).
- **Self-fencing.** 30 s lease, renewed every loop; the holder stops settling when under 10 s remain. A primary that cannot reach quorum cannot renew, so it fences itself before the secondary takes over.
- **Primary recovers mid-failover with work in memory.** It holds epoch `N`, the secondary `N+1`. Already-recorded settlements fail the condition check; new events may be journaled but not settled (lease check fails); unacknowledged SQS messages return to the queue and are settled once by the lease holder.

## Control plane vs data plane

Failover uses only data planes or healthy-region control planes. **Traffic:** ARC `UpdateRoutingControlStates` on any of 5 regional cluster endpoints; DNS answers come from Route 53's global data plane, not `ChangeResourceRecordSets`. **Credentials:** pre-provisioned break-glass roles through regional STS in `us-east-2`; no IAM changes during the incident (IAM's control plane is in `us-east-1`). **Compute, secrets, images:** already running in `us-east-2`, with Secrets Manager replicas under a local CMK and ECR replication. **Ledger:** no action; the healthy majority keeps writing. **Aurora:** `failover-global-cluster` is called on the `us-east-2` endpoint. **Terraform:** frozen, because state lives in `us-east-1`.

## Runbook: first 30 minutes

From the offline incident vault the operator exports `ARC_EP` (try the next endpoint on failure), `RC_PRIMARY`, `RC_SECONDARY` (`terraform output arc_cluster_endpoints`) and `T=aetherpay-prod-ledger-journal`. Each `# gate:` must pass before the next step.

```bash
# T+0  SEV1 page; name incident commander, comms and operator; disable the terraform-apply workflow
# T+3  probe both regions + AWS Health Dashboard
for h in use1 use2; do curl -s -o /dev/null -w "$h %{http_code} %{time_total}s\n" https://$h.webhooks.example.com/healthz; done
#      gate: fail over if primary errors > 5% or p99 > 3 s for 5 min (do not wait for a full outage)
# T+6  credentials from the healthy region
aws sts assume-role --region us-east-2 --role-arn <breakglass> --role-session-name sev1    # gate: get-caller-identity works
# T+8  secondary readiness
aws ecs describe-services --region us-east-2 --cluster aetherpay-prod-use2 --services aetherpay-prod-use2-ingestor aetherpay-prod-use2-settler
aws dynamodb describe-table --region us-east-2 --table-name $T --query 'Table.Replicas'   # gate: tasks healthy, replica ACTIVE, /healthz 200
# T+10 pre-scale to primary capacity (settler: --min-capacity 3)
aws application-autoscaling register-scalable-target --region us-east-2 --service-namespace ecs --scalable-dimension ecs:service:DesiredCount \
  --resource-id service/aetherpay-prod-use2/aetherpay-prod-use2-ingestor --min-capacity 6 --max-capacity 60
# T+13 FENCE the primary: the epoch increments, so the old holder can no longer settle (best effort: scale the use1 settler to 0)
aws dynamodb update-item --region us-east-2 --table-name $T --return-values ALL_NEW \
  --key '{"pk":{"S":"FENCE#settlement"},"sk":{"S":"LEASE"}}' \
  --update-expression 'SET epoch = epoch + :one, holder = :h, expires_at = :exp' --condition-expression 'holder <> :h' \
  --expression-attribute-values '{":one":{"N":"1"},":h":{"S":"us-east-2"},":exp":{"N":"'$(( $(date +%s) + 30 ))'"}}'
#      gate: holder = us-east-2 with the new epoch; primary settlers log "lease lost, fencing" or are unreachable
# T+15 SHIFT TRAFFIC in one ARC call (the safety rule keeps at least one region On)
aws route53-recovery-cluster update-routing-control-states --region us-west-2 --endpoint-url $ARC_EP \
  --update-routing-control-state-entries RoutingControlArn=$RC_SECONDARY,RoutingControlState=On RoutingControlArn=$RC_PRIMARY,RoutingControlState=Off
#      gate: get-routing-control-state on the primary is Off; dig returns use2 ALB addresses within 60 s
# T+20 promote Aurora, then start the journal-to-Aurora replay        gate: writer is use2, replay lag 0
aws rds failover-global-cluster --region us-east-2 --global-cluster-identifier aetherpay-prod-settlement \
  --target-db-cluster-identifier <use2-cluster-arn> --allow-data-loss
# T+25 signed synthetic webhook, then read it back
aws dynamodb get-item --region us-east-2 --table-name $T --consistent-read --key '{"pk":{"S":"TXN#synthetic-<id>"},"sk":{"S":"ENTRY#0"}}'
#      gate: 202, row present, queue age falling, DLQ empty, 5xx alarm OK
# T+30 ask payment networks to lift suspensions; status page; 30-min updates
#      failback only after 2 h healthy, as a planned switchover, lease handover and ARC flip
```

## Consequences

Zero ledger loss and no split brain by construction, with no dependency on the `us-east-1` control plane. The costs are higher journal write latency, no multi-item transactions on MRSC tables, the ARC cluster and paid warm standby. Follow-ups: replicate the state bucket to `us-east-2`, run quarterly packet-loss game days with AWS FIS, and automate T+8 to T+15 as an ARC Region switch plan with human approval.
