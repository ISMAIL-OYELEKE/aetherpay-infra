config {
  call_module_type = "local"
  force            = false
}

plugin "terraform" {
  enabled = true
  preset  = "all"
}

plugin "aws" {
  enabled = true
  version = "0.45.0"
  source  = "github.com/terraform-linters/tflint-ruleset-aws"
}

# Module-internal variables are documented via descriptions; versions are
# pinned once per root configuration.
rule "terraform_standard_module_structure" {
  enabled = false
}
