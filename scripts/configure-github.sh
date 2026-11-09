#!/usr/bin/env bash
# Copies the bootstrap outputs into GitHub Actions repository variables and
# creates the staging/production environments. Run once after
# `terraform -chdir=terraform/bootstrap apply`, with the GitHub CLI logged in
# (`gh auth login`) as a repository admin.
#
#   scripts/configure-github.sh <owner/repo> <staging-domain> <route53-zone-id> [alarm-email]
set -euo pipefail

REPO="${1:?owner/repo}"
DOMAIN="${2:?staging webhook domain, e.g. webhooks.staging.example.com}"
ZONE_ID="${3:?Route 53 hosted zone id}"
ALARM_EMAIL="${4:-}"

out() { terraform -chdir=terraform/bootstrap output -raw "$1"; }
outj() { terraform -chdir=terraform/bootstrap output -json "$1" | jq -r ".$2"; }

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
REGION="${AWS_REGION:-us-east-1}"

set_var() { gh variable set "$1" --repo "$REPO" --body "$2" >/dev/null && echo "set $1"; }

set_var AWS_REGION "$REGION"
set_var TF_STATE_BUCKET "$(out state_bucket)"
set_var TF_STATE_KMS_KEY_ARN "$(out state_kms_key_arn)"
set_var ECR_REPOSITORY_URL "$(out ecr_repository_url)"
set_var AWS_IMAGE_PUSH_ROLE_ARN "$(out image_push_role_arn)"

for env in staging production; do
  upper="$(echo "$env" | tr '[:lower:]' '[:upper:]')"
  set_var "AWS_PLAN_ROLE_ARN_${upper}" "$(outj plan_role_arns "$env")"
  set_var "AWS_APPLY_ROLE_ARN_${upper}" "$(outj apply_role_arns "$env")"
  gh api -X PUT "repos/${REPO}/environments/${env}" >/dev/null && echo "environment ${env} ready"
done

emails="[]"
[[ -n "$ALARM_EMAIL" ]] && emails="[\"${ALARM_EMAIL}\"]"

set_var TFVARS_STAGING "$(cat <<HCL
ecr_repository_arn       = "$(out ecr_repository_arn)"
permissions_boundary_arn = "$(out workload_permissions_boundary_arn)"
key_admin_arns           = ["arn:aws:iam::${ACCOUNT_ID}:role/aetherpay-gha-apply-staging"]
domain_name              = "${DOMAIN}"
hosted_zone_id           = "${ZONE_ID}"
alarm_emails             = ${emails}
HCL
)"

echo
echo "Done. Next: add SLACK_WEBHOOK_URL / PAGERDUTY_ROUTING_KEY secrets (optional),"
echo "then run the app-ci workflow on main to build the first image."
