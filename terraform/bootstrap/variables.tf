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
