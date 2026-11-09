# Application image, pinned by digest. Promotion = a reviewed PR that changes
# this line (the app-ci workflow prints the digest after every build on main).
# Until the first image is built, leave it commented: the plan then fails fast
# with "No value for required variable", which is intended.
#
app_image = "768499314608.dkr.ecr.us-east-1.amazonaws.com/aetherpay/app@sha256:210b5a48f34c269f697a3be455d81737848bce0f66007531bb3913021279dffc"
