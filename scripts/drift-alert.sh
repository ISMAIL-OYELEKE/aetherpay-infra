#!/usr/bin/env bash
# Sends a drift / plan-error alert to Slack (incoming webhook) and PagerDuty
# (Events API v2). Inputs come from environment variables set by the
# drift-detection workflow. Missing destinations are skipped, never fatal.
set -euo pipefail

: "${STATUS:?}" "${EXIT_CODE:?}" "${ENVIRONMENT:?}" "${RUN_URL:?}"
DRIFT_FILE="${DRIFT_FILE:-}"

if [[ "$STATUS" == "drift" ]]; then
  title="Terraform drift detected in ${ENVIRONMENT}"
  severity="warning"
  [[ "$ENVIRONMENT" == "production" ]] && severity="error"
else
  title="Terraform drift check FAILED to run in ${ENVIRONMENT} (exit ${EXIT_CODE})"
  severity="critical"
fi

changes="(none listed)"
if [[ -n "$DRIFT_FILE" && -s "$DRIFT_FILE" ]]; then
  changes="$(head -n 25 "$DRIFT_FILE")"
  total="$(wc -l < "$DRIFT_FILE" | tr -d ' ')"
  (( total > 25 )) && changes+=$'\n'"... and $((total - 25)) more"
fi

if [[ -n "${SLACK_WEBHOOK_URL:-}" ]]; then
  jq -n --arg title "$title" --arg changes "$changes" --arg url "$RUN_URL" --arg sev "$severity" '{
    text: $title,
    blocks: [
      { type: "header", text: { type: "plain_text", text: $title } },
      { type: "section", fields: [
          { type: "mrkdwn", text: "*Severity*\n\($sev)" },
          { type: "mrkdwn", text: "*Run*\n<\($url)|GitHub Actions>" } ] },
      { type: "section", text: { type: "mrkdwn", text: "```\($changes)```" } },
      { type: "context", elements: [ { type: "mrkdwn",
          text: "Someone changed infrastructure outside Terraform, or the plan could not run. Reconcile via a PR; do not apply from a laptop." } ] }
    ]
  }' | curl -fsS -X POST -H 'Content-Type: application/json' --data @- "$SLACK_WEBHOOK_URL" >/dev/null
  echo "Slack alert sent"
else
  echo "SLACK_WEBHOOK_URL not set; skipping Slack"
fi

if [[ -n "${PAGERDUTY_ROUTING_KEY:-}" ]]; then
  jq -n --arg key "$PAGERDUTY_ROUTING_KEY" --arg title "$title" --arg sev "$severity" \
        --arg env "$ENVIRONMENT" --arg url "$RUN_URL" --arg changes "$changes" --arg status "$STATUS" '{
    routing_key: $key,
    event_action: "trigger",
    dedup_key: "terraform-drift-\($env)",
    payload: {
      summary: $title,
      source: "github-actions/drift-detection",
      severity: $sev,
      component: "terraform",
      group: $env,
      class: $status,
      custom_details: { changes: $changes, run: $url }
    },
    links: [ { href: $url, text: "Drift run" } ]
  }' | curl -fsS -X POST -H 'Content-Type: application/json' --data @- https://events.pagerduty.com/v2/enqueue >/dev/null
  echo "PagerDuty event sent"
else
  echo "PAGERDUTY_ROUTING_KEY not set; skipping PagerDuty"
fi
