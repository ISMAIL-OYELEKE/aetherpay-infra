variable "primary_region" {
  description = "Primary (active) region."
  type        = string
  default     = "us-east-1"
}

variable "secondary_region" {
  description = "Secondary (warm standby) region. Must be in the same DynamoDB MRSC region set."
  type        = string
  default     = "us-east-2"
}

variable "witness_region" {
  description = "Ledger MRSC witness region."
  type        = string
  default     = "us-west-2"
}

variable "primary_azs" {
  description = "AZs in the primary region."
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b", "us-east-1c"]
}

variable "secondary_azs" {
  description = "AZs in the secondary region."
  type        = list(string)
  default     = ["us-east-2a", "us-east-2b", "us-east-2c"]
}

variable "global_domain_name" {
  description = "Partner-facing webhook FQDN, failover-routed by ARC (e.g. webhooks.example.com)."
  type        = string
}

variable "hosted_zone_id" {
  description = "Public hosted zone for all webhook records."
  type        = string
}

variable "app_image_primary" {
  description = "Image digest in the primary region's registry."
  type        = string

  validation {
    condition     = can(regex("@sha256:[a-f0-9]{64}$", var.app_image_primary))
    error_message = "Pin the image by digest (repo@sha256:<64 hex>); mutable tags are rejected."
  }
}

variable "app_image_secondary" {
  description = "Same digest in the replicated registry of the secondary region."
  type        = string

  validation {
    condition     = can(regex("@sha256:[a-f0-9]{64}$", var.app_image_secondary))
    error_message = "Pin the image by digest (repo@sha256:<64 hex>); mutable tags are rejected."
  }
}

variable "ecr_repository_arn" {
  description = "Shared ECR repository ARN (primary region)."
  type        = string
}

variable "permissions_boundary_arn" {
  description = "Workload permissions boundary ARN."
  type        = string
}

variable "key_admin_arns" {
  description = "CMK administrators."
  type        = list(string)
  default     = []
}

variable "alarm_emails" {
  description = "Alarm email subscribers."
  type        = list(string)
  default     = []
}
