variable "name" {
  description = "Name prefix for the regional stack, e.g. aetherpay-staging."
  type        = string
}

variable "region_role" {
  description = "primary or secondary. Exposed to the app so it knows whether it may claim settlement leases."
  type        = string
  default     = "primary"

  validation {
    condition     = contains(["primary", "secondary"], var.region_role)
    error_message = "region_role must be primary or secondary."
  }
}

variable "azs" {
  description = "Three Availability Zones."
  type        = list(string)
}

variable "vpc_cidr" {
  description = "Regional /20 block."
  type        = string
  default     = "10.24.0.0/20"
}

variable "ingress_cidrs" {
  description = "Source CIDRs allowed to reach the ALB."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "enable_nat_gateway" {
  description = "Provision NAT gateways for allow-listed egress."
  type        = bool
  default     = false
}

variable "nat_egress_cidrs" {
  description = "Allow-listed partner CIDRs reachable via NAT."
  type        = list(string)
  default     = []
}

variable "domain_name" {
  description = "Regional webhook FQDN."
  type        = string
}

variable "certificate_sans" {
  description = "Extra certificate names, e.g. the global hostname that ARC routes to this region."
  type        = list(string)
  default     = []
}

variable "create_san_validation_records" {
  description = "Own the DNS validation records for certificate_sans (true in exactly one region)."
  type        = bool
  default     = true
}

variable "hosted_zone_id" {
  description = "Route 53 zone for certificate validation and alias records."
  type        = string
  default     = null
}

variable "certificate_arn" {
  description = "Existing ACM certificate (alternative to hosted_zone_id)."
  type        = string
  default     = null
}

variable "app_image" {
  description = "Application image pinned by digest."
  type        = string
}

variable "ecr_repository_arn" {
  description = "Override the ECR repository ARN (secondary regions pull from a replicated repository)."
  type        = string
  default     = null
}

variable "create_repository" {
  description = "Create the ECR repository in this region."
  type        = bool
  default     = true
}

variable "ecr_replication_regions" {
  description = "Replicate images to these regions."
  type        = list(string)
  default     = []
}

variable "ledger" {
  description = "Ledger journal coordinates for this region."
  type = object({
    table_name  = string
    table_arn   = string
    kms_key_arn = string
  })
}

variable "create_signing_secrets" {
  description = "Create and rotate signing secrets in this region. Secondary regions set false and pass external_signing_secret_arns."
  type        = bool
  default     = true
}

variable "external_signing_secret_arns" {
  description = "Signing secrets replicated from the primary region (used when create_signing_secrets = false)."
  type        = map(string)
  default     = null
}

variable "secret_replica_regions" {
  description = "Replicate this region's signing secrets: region => CMK ARN in that region."
  type        = map(string)
  default     = {}
}

variable "additional_secret_vpce_ids" {
  description = "Secrets Manager endpoint IDs in DR regions allowed to read the replicated secrets."
  type        = list(string)
  default     = []
}

variable "ingestor" {
  description = "Ingestor sizing."
  type = object({
    cpu                 = optional(number, 512)
    memory              = optional(number, 1024)
    min_capacity        = optional(number, 3)
    max_capacity        = optional(number, 30)
    requests_per_target = optional(number, 1500)
  })
  default = {}
}

variable "settler" {
  description = "Settler sizing and queue-scaling targets."
  type = object({
    cpu                     = optional(number, 512)
    memory                  = optional(number, 1024)
    min_capacity            = optional(number, 2)
    max_capacity            = optional(number, 40)
    backlog_per_task_target = optional(number, 100)
    burst_age_seconds       = optional(number, 120)
  })
  default = {}
}

variable "db" {
  description = "Aurora sizing and topology."
  type = object({
    min_acu                   = optional(number, 0.5)
    max_acu                   = optional(number, 8)
    instance_count            = optional(number, 2)
    global_cluster_identifier = optional(string)
    is_secondary_region       = optional(bool, false)
    # Static flag (the identifier is often unknown until apply) that selects
    # the Aurora Global credential path instead of the RDS-managed secret.
    is_global_member = optional(bool, false)
  })
  default = {}
}

variable "cache" {
  description = "ElastiCache sizing."
  type = object({
    node_type = optional(string, "cache.t4g.small")
    replicas  = optional(number, 2)
  })
  default = {}
}

variable "deletion_protection" {
  description = "Protect stateful resources (Aurora, ALB, log buckets)."
  type        = bool
  default     = true
}

variable "log_retention_days" {
  description = "Default CloudWatch log retention."
  type        = number
  default     = 365
}

variable "alarm_emails" {
  description = "Email subscribers for operational alarms (PagerDuty/Slack can subscribe to the topic too)."
  type        = list(string)
  default     = []
}

variable "key_admin_arns" {
  description = "Principals that administer CMKs."
  type        = list(string)
  default     = []
}

variable "permissions_boundary_arn" {
  description = "Permissions boundary attached to every role the stack creates."
  type        = string
  default     = null
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
  default     = {}
}
