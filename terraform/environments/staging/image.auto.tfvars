# Application image, pinned by digest. Promotion = a reviewed PR that changes
# this line (the app-ci workflow prints the digest after every build on main).
# Until the first image is built, leave it commented: the plan then fails fast
# with "No value for required variable", which is intended.
#
# app_image = "<account_id>.dkr.ecr.us-east-1.amazonaws.com/aetherpay/app@sha256:<digest>"
