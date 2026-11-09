# Production promotes the same digest that ran in staging. The secondary
# region pulls it from the replicated registry.
#
# app_image_primary   = "<account_id>.dkr.ecr.us-east-1.amazonaws.com/aetherpay/app@sha256:<digest>"
# app_image_secondary = "<account_id>.dkr.ecr.us-east-2.amazonaws.com/aetherpay/app@sha256:<digest>"
