#!/usr/bin/env bash
# Smoke test for a deployed environment. Run from a machine with AWS CLI
# credentials for the account (read access to ECS and CloudWatch Logs, and
# ecs:RunTask on the ingestor task definition).
#
#   scripts/smoke-test.sh https://aetherpay-staging.example.com aetherpay-staging
#
# 1. TLS: TLS 1.3 is accepted, TLS 1.2 is refused by the load balancer.
# 2. Health check answers 200.
# 3. A webhook with a wrong signature is rejected with 401.
# 4. A correctly signed webhook is accepted (202), and a replay of the same
#    event id is reported as a duplicate (200).
#    The signing key can only be read by the ingestor workload, through the VPC
#    endpoint (secret resource policy), so not even an admin on a laptop can
#    read it. The script therefore starts a one-off copy of the ingestor task,
#    which signs one test body and prints only the signature (never the key).
# 5. WAF: a burst from one IP is answered with 429 once the rate limit trips.
set -euo pipefail

URL="${1:?usage: smoke-test.sh <base-url> <name, e.g. aetherpay-staging>}"
NAME="${2:?usage: smoke-test.sh <base-url> <name, e.g. aetherpay-staging>}"
CLUSTER="$NAME"
SERVICE="$NAME-ingestor"
LOG_GROUP="/aetherpay/ecs/$NAME-ingestor"
BODY='{"type":"payment.settled","amount":"10.00","currency":"USD"}'

step() { printf '\n\033[1m== %s\033[0m\n' "$*"; }

step "1. TLS"
if curl -s -o /dev/null --tlsv1.3 --tls-max 1.3 "$URL/healthz"; then echo "TLS 1.3: accepted"; fi
if curl -s -o /dev/null --tlsv1.2 --tls-max 1.2 "$URL/healthz" 2>/dev/null; then
  echo "TLS 1.2: ACCEPTED (unexpected)"
else
  echo "TLS 1.2: refused (expected)"
fi

step "2. Health check"
curl -s -w '  -> HTTP %{http_code}\n' "$URL/healthz"

step "3. Wrong signature"
ts=$(date +%s)
curl -s -w '  -> HTTP %{http_code}\n' -X POST "$URL/webhooks/acme" \
  -H 'Content-Type: application/json' \
  -H "X-AetherPay-Event-Id: evt-bad-$ts" \
  -H "X-AetherPay-Signature: t=$ts,v1=0000000000000000000000000000000000000000000000000000000000000000" \
  --data "$BODY"

step "4. Correct signature (signed inside the workload)"
net=$(aws ecs describe-services --cluster "$CLUSTER" --services "$SERVICE" \
  --query 'services[0].networkConfiguration' --output json)
started=$(($(date +%s) * 1000))
script="import os,time; from aetherpay.keys import SigningKeyProvider; from aetherpay import signature; \
k=SigningKeyProvider(os.environ['PARTNER_HMAC_KEY_ARN']).keys()[0]; t=int(time.time()); \
print('SMOKE_SIGNATURE', t, signature.sign(k, t, os.environ['SMOKE_BODY'].encode()), flush=True)"
overrides=$(printf '{"containerOverrides":[{"name":"app","command":["python","-c",%s],"environment":[{"name":"SMOKE_BODY","value":%s}]}]}' \
  "$(printf '%s' "$script" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')" \
  "$(printf '%s' "$BODY" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')")
task=$(aws ecs run-task --cluster "$CLUSTER" --task-definition "$SERVICE" --launch-type FARGATE \
  --network-configuration "$net" --overrides "$overrides" --query 'tasks[0].taskArn' --output text)
echo "one-off signer task: ${task##*/} (about a minute)"
aws ecs wait tasks-stopped --cluster "$CLUSTER" --tasks "$task"
line=""
for _ in 1 2 3 4 5 6; do
  line=$(aws logs filter-log-events --log-group-name "$LOG_GROUP" --start-time "$started" \
    --filter-pattern '"SMOKE_SIGNATURE"' --query 'events[-1].message' --output text 2>/dev/null || true)
  [ -n "$line" ] && [ "$line" != "None" ] && break
  sleep 5
done
read -r _ sts sig <<<"$line"
[ -n "${sig:-}" ] || { echo "could not read the signature from $LOG_GROUP"; exit 1; }
evt="evt-smoke-$sts"
for attempt in first replay; do
  printf '%s: ' "$attempt"
  curl -s -w '  -> HTTP %{http_code}\n' -X POST "$URL/webhooks/acme" \
    -H 'Content-Type: application/json' \
    -H "X-AetherPay-Event-Id: $evt" \
    -H "X-AetherPay-Signature: t=$sts,v1=$sig" \
    --data "$BODY"
done

step "5. WAF rate limit (burst of 1500 requests from this IP)"
seq 1500 | xargs -P 40 -I{} curl -s -o /dev/null -w '%{http_code}\n' "$URL/healthz" | sort | uniq -c
echo "If no 429 yet, WAF counts in the background: wait ~30s and run:"
echo "  for i in 1 2 3 4 5; do curl -s -o /dev/null -w '%{http_code}\\n' $URL/healthz; done"
