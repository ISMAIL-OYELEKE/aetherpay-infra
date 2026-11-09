# ADR-001: Multi-Region Resiliency and Disaster Recovery

- **Status:** Accepted
- **Scope:** Production. Primary `us-east-1`, secondary `us-east-2`, ledger witness and ARC config in `us-west-2`
- **Code:** `modules/ledger`, `modules/dr-routing`, `environments/production`

## Context

At 02:15 UTC the primary region suffers a control-plane outage (networking and storage APIs) with a partially degraded data plane: about 40% packet loss. It is an **asymmetric partition**: the region is not dead, so health checks flap, while partner webhooks time out and payment networks start auto-suspending us. The dangerous failure is not the outage itself. It is that the degraded primary keeps (or later resumes) settling transactions after we fail over, which causes **split-brain writes and double settlement**.

## Decision

1. **The ledger journal is the system of record and is synchronously replicated.** It is a DynamoDB global table with **Multi-Region Strong Consistency (MRSC)**: two full replicas (`us-east-1`, `us-east-2`) plus a witness (`us-west-2`). A write is acknowledged only once it is durable in 2 of the 3 regions.
2. **Settlement has exactly one active writer**, enforced by a monotonic **fencing epoch** stored in that same quorum table. Storage is active-active; settlement authority is active-passive.
3. **Everything else is warm standby.** The secondary runs the full stack at reduced capacity: Aurora Global secondary, replicated signing secrets and container images.
4. **Traffic moves with Route 53 ARC routing controls**, flipped through ARC's multi-region data plane. Failover never calls a control-plane API in the failing region.

## RPO and RTO targets

| Data / capability | RPO | RTO | How it is achieved |
|---|---|---|---|
| Immutable ledger journal | **0** | ≤ 15 min (writes never stop in the healthy majority) | MRSC quorum acknowledgement. An acknowledged entry exists in at least 2 regions. |
| Settlement batch workspace (Aurora) | ≤ 1 s replication lag; financially **0** | ≤ 15 min | Aurora Global failover. Any lost tail is replayed from the journal stream, because Aurora is a projection, not the source of truth. |
| Verified-but-unsettled events (SQS) | 0 for anything acknowledged to a partner as settled; in-flight events are re-delivered | ≤ 15 min | Partners retry until they get `202`, which is sent only after a durable enqueue. Events stranded in the primary queue are processed after recovery and de-duplicated by the ledger. |
| Webhook de-duplication cache | Not preserved (rebuilt) | ≤ 5 min (cache already warm in secondary) | Duplicates are harmless because ledger writes are idempotent (below). |
| Session state | Not preserved | ≤ 5 min | Clients re-authenticate. |

## Active-passive vs active-active for the ledger

| | Active-passive (Aurora Global Database) | Active-active (DynamoDB MRSC) **chosen for the journal** |
|---|---|---|
| Replication | Asynchronous storage replication, single writer | Synchronous quorum (2 of 3 regions) |
| RPO | ~1 s typical; unplanned failover uses `--allow-data-loss` | 0 |
| Split-brain risk | Old writer can accept writes until fenced; needs external fencing | A partitioned minority **cannot reach quorum, so its writes fail** instead of diverging |
| Write latency | Local | Cross-region round trip (tens of ms), acceptable for settlement |
| Constraints | Full SQL, transactions | Single-item conditional writes; no multi-item transactions on MRSC tables (we design around them) |

Aurora stays as the relational settlement workspace (batching, reporting), where a sub-second RPO is acceptable because it can be rebuilt from the journal.

## Fencing and quorum: preventing split brain and double settlement

**Quorum.** Every journal write goes to the MRSC table. During the partition, a primary losing 40% of packets either reaches the quorum (then its write is linearizable and visible everywhere) or it does not (then the write fails). There is no third outcome where two regions accept conflicting versions.

**Idempotency at the row.** Each settlement is written as `pk = TXN#<settlement_id>` with `ConditionExpression: attribute_not_exists(pk)`. The `settlement_id` is the payment rail's own idempotency key. A second attempt to write the same settlement, from any region and at any time, fails with `ConditionalCheckFailedException`. This alone makes **double-recording impossible**.

**Fencing epoch for side effects.** Submitting a batch to a payment network is an external side effect that the database cannot undo, so it needs a single authority:

1. The lease item `pk = FENCE#settlement` holds `{epoch, holder_region, expires_at}`. A settler acquires or renews it with a conditional `UpdateItem` (`SET epoch = epoch + 1, holder = :me ...` when expired or already held by `:me`). The IAM policy only lets settlers update `FENCE#*` and `BATCH#*` keys (`dynamodb:LeadingKeys`).
2. A batch is claimed with `PutItem BATCH#<batch_id>` (`attribute_not_exists`) carrying the claimant's epoch. Immediately before the external call, the worker does a strongly consistent read of the lease and aborts unless `epoch == mine`.
3. **Self-fencing.** A holder stops all settlement work when the remaining lease time drops below a safety margin (lease 30 s, renew every 10 s, stop at under 10 s, measured on a monotonic clock). A degraded primary that cannot reach the quorum cannot renew, so it fences itself before the secondary can take over.
4. The batch ID is passed to the payment network as its idempotency key, which closes the last read-then-act window.

**The degraded primary recovers mid-failover with transactions still in memory.** Its epoch is `N`; the secondary now holds `N+1`.
- Journal writes for settlements the secondary already recorded fail the `attribute_not_exists` check and are dropped.
- New, never-seen events may be journaled, which is correct because they are real, verified events. They cannot be *settled* by the old holder: its lease check fails (`N ≠ N+1`) and it cannot renew because `holder ≠ :me`.
- Unacknowledged SQS messages in the primary return to the queue after the visibility timeout. They are processed by whichever region holds the lease once the primary is healthy, and de-duplicated by the journal.

## Control plane vs data plane

The failover path uses only data-plane operations, or control planes in healthy regions:

| Need | Mechanism | Why it survives a `us-east-1` control-plane outage |
|---|---|---|
| Move partner traffic | ARC `UpdateRoutingControlStates` against any of the **5 regional cluster endpoints** (3 needed) | ARC's data plane is independent of Route 53's control plane (`ChangeResourceRecordSets`). DNS answers and health checks come from Route 53's global data plane. |
| Credentials | Pre-provisioned break-glass roles; `aws sts assume-role --region us-east-2` (regional STS) | The IAM control plane lives in `us-east-1`, so **no IAM changes are made during the incident**. The IAM Identity Center home region is outside `us-east-1`. |
| Compute in secondary | Already running (warm standby). Scaling calls go to `us-east-2` APIs. | Nothing has to be created in the failing region. |
| Secrets | Secrets Manager replicas in `us-east-2`, encrypted with a `us-east-2` CMK | Read locally; rotation pauses until the primary returns, and the overlap window covers it. |
| Images | ECR cross-region replication | Pulled from the `us-east-2` registry through local VPC endpoints. |
| Ledger | MRSC | No failover action at all; the healthy majority keeps writing. |
| Aurora | `failover-global-cluster` called on the **`us-east-2`** endpoint | Executed by the target region. |
| Terraform | **Not used during the incident** | State lives in `us-east-1`; infrastructure changes are frozen until recovery. |

## Runbook: first 30 minutes

Pre-reqs kept offline in the incident vault: ARC cluster endpoints and routing-control ARNs (`terraform output arc_cluster_endpoints`), and break-glass role ARNs.

```bash
export ARC_EP=https://<id>.route53-recovery-cluster.us-west-2.amazonaws.com/v1   # try the next endpoint on failure
export RC_PRIMARY=arn:aws:route53-recovery-control::<acct>:controlpanel/<cp>/routingcontrol/<primary>
export RC_SECONDARY=arn:aws:route53-recovery-control::<acct>:controlpanel/<cp>/routingcontrol/<secondary>
export T=aetherpay-prod-ledger-journal
```

| Time | Action | Verification gate |
|---|---|---|
| **T+0** | PagerDuty SEV1 (ALB 5xx alarm, partner timeout alarm). Incident commander, comms lead and operator assigned; deploys frozen (disable the `terraform-apply` workflow). | Bridge open, roles named. |
| **T+3** | Confirm it is regional and not us: run external probes against both regional hostnames.<br>`for h in use1 use2; do curl -s -o /dev/null -w "$h %{http_code} %{time_total}s\n" https://$h.webhooks.example.com/healthz; done`<br>Check the AWS Health Dashboard for `us-east-1`. | **Fail over if** the primary error rate is over 5% or p99 is over 3 s for 5 min, or partners report timeouts. Do not wait for a full outage; a partial partition is the trigger. |
| **T+6** | Get credentials in the healthy region:<br>`aws sts assume-role --region us-east-2 --role-arn <breakglass> --role-session-name sev1` | `aws sts get-caller-identity --region us-east-2` succeeds. |
| **T+8** | Check secondary readiness:<br>`aws ecs describe-services --region us-east-2 --cluster aetherpay-prod-use2 --services aetherpay-prod-use2-ingestor aetherpay-prod-use2-settler --query 'services[].{s:serviceName,run:runningCount,want:desiredCount}'`<br>`aws dynamodb describe-table --region us-east-2 --table-name $T --query 'Table.Replicas[].{r:RegionName,s:ReplicaStatus}'` | Tasks healthy; ledger replica `ACTIVE`; `use2` `/healthz` returns 200. |
| **T+10** | Pre-scale the secondary to primary capacity:<br>`aws application-autoscaling register-scalable-target --region us-east-2 --service-namespace ecs --scalable-dimension ecs:service:DesiredCount --resource-id service/aetherpay-prod-use2/aetherpay-prod-use2-ingestor --min-capacity 6 --max-capacity 60` (repeat for the settler with `--min-capacity 3`) | `runningCount` reaches the new minimum. |
| **T+13** | **Fence the primary**: take the settlement lease for `us-east-2` (the epoch increments):<br>`aws dynamodb update-item --region us-east-2 --table-name $T --key '{"pk":{"S":"FENCE#settlement"},"sk":{"S":"LEASE"}}' --update-expression 'SET epoch = epoch + :one, holder_region = :h, expires_at = :exp' --condition-expression 'holder_region <> :h' --expression-attribute-values '{":one":{"N":"1"},":h":{"S":"us-east-2"},":exp":{"N":"'$(( $(date +%s) + 30 ))'"}}' --return-values ALL_NEW`<br>Best effort only: `aws ecs update-service --region us-east-1 --cluster aetherpay-prod-use1 --service aetherpay-prod-use1-settler --desired-count 0` | `ALL_NEW` shows `holder_region = us-east-2` and the new epoch. Primary settlers log `lease lost, fencing` (or are unreachable, which is equally safe). |
| **T+15** | **Shift traffic** (one atomic call; the safety rule keeps at least one region On):<br>`aws route53-recovery-cluster update-routing-control-states --region us-west-2 --endpoint-url $ARC_EP --update-routing-control-state-entries RoutingControlArn=$RC_SECONDARY,RoutingControlState=On RoutingControlArn=$RC_PRIMARY,RoutingControlState=Off` | `aws route53-recovery-cluster get-routing-control-state --region us-west-2 --endpoint-url $ARC_EP --routing-control-arn $RC_PRIMARY` returns `Off`; `dig +short webhooks.example.com @1.1.1.1` returns `use2` ALB addresses within 60 s (record TTL). |
| **T+20** | Promote Aurora in the secondary:<br>`aws rds failover-global-cluster --region us-east-2 --global-cluster-identifier aetherpay-prod-settlement --target-db-cluster-identifier arn:aws:rds:us-east-2:<acct>:cluster:aetherpay-prod-use2-settlement --allow-data-loss`<br>Then start the journal-to-Aurora replay from the last projection checkpoint. | `aws rds describe-global-clusters --region us-east-2 --query 'GlobalClusters[0].GlobalClusterMembers[?IsWriter].DBClusterArn'` shows `use2`; replay lag drops to 0. |
| **T+25** | End-to-end check: send a signed synthetic webhook to `https://webhooks.example.com/webhooks/synthetic`, then read it back:<br>`aws dynamodb get-item --region us-east-2 --table-name $T --consistent-read --key '{"pk":{"S":"TXN#synthetic-<id>"},"sk":{"S":"ENTRY#0"}}'` | `202` returned; journal row present; SQS `ApproximateAgeOfOldestMessage` falling; DLQ empty; ALB 5xx alarm `OK`. |
| **T+30** | Ask payment networks to lift suspensions; post a status-page update; hand partners the replay window (they retry automatically). Schedule 30-minute updates. Record the timeline. | Partner acknowledgements logged. **No failback** until the primary has been healthy for 2 h; failback is a planned Aurora *switchover* (no data loss), a lease handover and an ARC flip, run as a normal change. |

## Consequences

- **Positive.** Zero ledger loss, no split-brain by construction (quorum plus idempotency plus fencing), and failover depends on no `us-east-1` control plane.
- **Negative.** Higher write latency on the journal, no multi-item transactions on MRSC tables, an ARC cluster that costs money (production only), and warm-standby capacity paid for in `us-east-2`.
- **Follow-ups.** Replicate the Terraform state bucket to `us-east-2`; run a quarterly game day that injects packet loss (AWS FIS `aws:network:disrupt-connectivity`) against the primary; automate T+8 to T+15 as an ARC Region switch plan, keeping a human approval step.
