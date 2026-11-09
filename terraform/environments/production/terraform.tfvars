# Non-secret production configuration. Image digests and account ARNs are
# injected by CI as TF_VAR_* from the "production" GitHub Environment.

global_domain_name = "webhooks.example.com"
hosted_zone_id     = "Z0123456789ABCDEFGHIJ"
