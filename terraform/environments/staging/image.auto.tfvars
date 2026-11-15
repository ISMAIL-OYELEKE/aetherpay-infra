# Application image, pinned by digest. Promotion = a reviewed PR that changes
# this line (the app-ci workflow prints the digest after every build on main).
# Until the first image is built, leave it commented: the plan then fails fast
# with "No value for required variable", which is intended.
# Account ID replaced with a placeholder for the public repo; staging is torn
# down. Put your account ID back (or let CI set TF_VAR_app_image) to redeploy.
#
app_image = "<ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com/aetherpay/app@sha256:500dcd223c8131f22214340da9d5d631d7c78896e9da17e4503d1541f4d59f91"
