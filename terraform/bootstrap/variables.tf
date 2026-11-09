variable "region" {
  description = "Home region for state, ECR and CI roles."
  type        = string
  default     = "us-east-1"
}

variable "github_repository" {
  description = "owner/repo allowed to assume the CI roles via OIDC."
  type        = string
  default     = "ISMAIL-OYELEKE/aetherpay-infra"
}

variable "github_oidc_subject_prefix" {
  description = <<-EOT
    Prefix of the GitHub OIDC "sub" claim for this repository. Check it with
    `gh api repos/<owner>/<repo>/actions/oidc/customization/sub`
    (sub_claim_prefix). Null means the legacy "repo:<owner>/<repo>" form.
  EOT
  type        = string
  default     = "repo:ISMAIL-OYELEKE@98213704/aetherpay-infra@1451362168"
}

variable "environments" {
  description = "Deployment environments that get dedicated plan/apply roles."
  type        = list(string)
  default     = ["staging", "production"]
}

variable "ecr_replication_regions" {
  description = "Regions the application image is replicated to (DR)."
  type        = list(string)
  default     = ["us-east-2"]
}

variable "create_github_oidc_provider" {
  description = "Set false if the account already has the GitHub OIDC provider."
  type        = bool
  default     = true
}
