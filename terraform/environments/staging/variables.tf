variable "region" {
  description = "Primary region."
  type        = string
  default     = "us-east-1"
}

variable "azs" {
  description = "Three AZs in the primary region."
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b", "us-east-1c"]
}

variable "ledger_replica_region" {
  description = "Ledger MRSC replica region."
  type        = string
  default     = "us-east-2"
}

variable "ledger_witness_region" {
  description = "Ledger MRSC witness region."
  type        = string
  default     = "us-west-2"
}

variable "domain_name" {
  description = "Webhook FQDN for staging, e.g. webhooks.staging.example.com."
  type        = string
}

variable "hosted_zone_id" {
  description = "Route 53 public hosted zone that owns domain_name. Null if certificate_arn is supplied."
  type        = string
  default     = null
}

variable "certificate_arn" {
  description = "Existing ACM certificate for domain_name (alternative to hosted_zone_id)."
  type        = string
  default     = null
}

variable "app_image" {
  description = "Application image pinned by digest. Supplied by CI (TF_VAR_app_image) after the image build."
  type        = string

  validation {
    condition     = can(regex("@sha256:[a-f0-9]{64}$", var.app_image))
    error_message = "Pin the image by digest (repo@sha256:<64 hex>); mutable tags are rejected."
  }
}

variable "ecr_repository_arn" {
  description = "Shared ECR repository ARN from the bootstrap stack."
  type        = string
}

variable "permissions_boundary_arn" {
  description = "Workload permissions boundary ARN from the bootstrap stack."
  type        = string
}

variable "key_admin_arns" {
  description = "CMK administrators (CI apply role, break-glass role)."
  type        = list(string)
  default     = []
}

variable "alarm_emails" {
  description = "Alarm email subscribers."
  type        = list(string)
  default     = []
}
