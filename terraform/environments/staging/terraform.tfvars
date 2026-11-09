# Non-secret staging configuration. app_image is injected by CI as TF_VAR_app_image.
# Account-specific values (ARNs) are injected as TF_VAR_* from GitHub
# Environment variables so this file stays account-agnostic.

domain_name = "webhooks.staging.example.com"
# hosted_zone_id  = "Z0123456789ABCDEFGHIJ"
# certificate_arn = "arn:aws:acm:us-east-1:<account_id>:certificate/<id>"
