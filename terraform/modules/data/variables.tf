variable "name" {
  description = "Name prefix, e.g. aetherpay-staging."
  type        = string
}

variable "isolated_subnet_ids" {
  description = "Isolated tier subnets (no internet, no NAT)."
  type        = list(string)
}

variable "db_security_group_id" {
  description = "Security group for Aurora."
  type        = string
}

variable "cache_security_group_id" {
  description = "Security group for ElastiCache."
  type        = string
}

variable "data_kms_key_arn" {
  description = "CMK for storage encryption."
  type        = string
}

variable "secrets_kms_key_arn" {
  description = "CMK for the RDS-managed master credential secret."
  type        = string
}

variable "logs_kms_key_arn" {
  description = "CMK for log groups."
  type        = string
}

# ------------------------------------------------------------------- Aurora
variable "db_engine_version" {
  description = "Aurora PostgreSQL engine version."
  type        = string
  default     = "16.6"
}

variable "db_name" {
  description = "Initial database name."
  type        = string
  default     = "settlement"
}

variable "db_min_acu" {
  description = "Serverless v2 minimum capacity (ACUs)."
  type        = number
  default     = 0.5
}

variable "db_max_acu" {
  description = "Serverless v2 maximum capacity (ACUs)."
  type        = number
  default     = 8
}

variable "db_instance_count" {
  description = "Writer + readers. Two or more gives Multi-AZ failover."
  type        = number
  default     = 2
}

variable "db_backup_retention_days" {
  description = "Automated backup retention."
  type        = number
  default     = 35
}

variable "deletion_protection" {
  description = "Protect stateful resources from accidental destroy."
  type        = bool
  default     = true
}

variable "global_cluster_identifier" {
  description = "Join an Aurora Global Database. Null for a standalone cluster."
  type        = string
  default     = null
}

variable "is_secondary_region" {
  description = "True when this cluster is a read-only Aurora Global secondary (no master credentials)."
  type        = bool
  default     = false
}

# -------------------------------------------------------------------- cache
variable "cache_engine_version" {
  description = "Valkey engine version (Redis OSS compatible)."
  type        = string
  default     = "8.0"
}

variable "cache_node_type" {
  description = "ElastiCache node type."
  type        = string
  default     = "cache.t4g.small"
}

variable "cache_replicas" {
  description = "Number of cache clusters (primary + replicas) across AZs."
  type        = number
  default     = 2
}

variable "cache_iam_user_name" {
  description = "ElastiCache user that workloads authenticate as with IAM (no password). Defaults to <name>-ingestor."
  type        = string
  default     = null
}

variable "log_retention_days" {
  description = "Log retention."
  type        = number
  default     = 365
}

variable "permissions_boundary_arn" {
  description = "Permissions boundary for IAM roles created here."
  type        = string
  default     = null
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
  default     = {}
}
