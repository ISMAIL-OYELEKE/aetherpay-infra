variable "name" {
  description = "Service name, e.g. aetherpay-staging-ingestor."
  type        = string
}

variable "cluster_arn" {
  description = "ECS cluster ARN."
  type        = string
}

variable "cluster_name" {
  description = "ECS cluster name (CloudWatch dimension)."
  type        = string
}

variable "image" {
  description = "Container image, pinned by digest (repo@sha256:...)."
  type        = string

  validation {
    condition     = can(regex("@sha256:[a-f0-9]{64}$", var.image))
    error_message = "Pin the image by digest (repo@sha256:<64 hex>). Mutable tags such as :latest are not allowed."
  }
}

variable "command" {
  description = "Container command override."
  type        = list(string)
  default     = null
}

variable "cpu" {
  description = "Task CPU units."
  type        = number
  default     = 512
}

variable "memory" {
  description = "Task memory (MiB)."
  type        = number
  default     = 1024
}

variable "cpu_architecture" {
  description = "X86_64 or ARM64."
  type        = string
  default     = "X86_64"
}

variable "container_port" {
  description = "Port the container listens on. Null for workers without a listener."
  type        = number
  default     = null
}

variable "health_check_path" {
  description = "Path probed by the container health check (when container_port is set)."
  type        = string
  default     = "/healthz"
}

variable "environment" {
  description = "Non-secret configuration only. Secrets are fetched at runtime from Secrets Manager by the task role."
  type        = map(string)
  default     = {}

  validation {
    condition = alltrue([
      for k in keys(var.environment) :
      length(regexall("(?i)(password|secret|token|private_key|api_key)", k)) == 0
    ])
    error_message = "Environment variables must not carry secrets. Read them from Secrets Manager at runtime."
  }
}

variable "task_role_arn" {
  description = "Least-privilege task role (workload identity)."
  type        = string
}

variable "subnet_ids" {
  description = "Private application subnets."
  type        = list(string)
}

variable "security_group_ids" {
  description = "Security groups for the task ENIs."
  type        = list(string)
}

variable "target_group_arn" {
  description = "ALB target group to register with. Null for workers."
  type        = string
  default     = null
}

variable "ecr_repository_arn" {
  description = "ECR repository the execution role may pull from."
  type        = string
}

variable "logs_kms_key_arn" {
  description = "CMK for the log group."
  type        = string
}

variable "log_retention_days" {
  description = "Log retention."
  type        = number
  default     = 365
}

variable "permissions_boundary_arn" {
  description = "Permissions boundary for the execution role."
  type        = string
  default     = null
}

# --------------------------------------------------------------- autoscaling
variable "min_capacity" {
  description = "Minimum running tasks (spread over 3 AZs)."
  type        = number
  default     = 2
}

variable "max_capacity" {
  description = "Maximum running tasks."
  type        = number
  default     = 20
}

variable "cpu_target_percent" {
  description = "Target average CPU utilisation."
  type        = number
  default     = 60
}

variable "memory_target_percent" {
  description = "Target average memory utilisation."
  type        = number
  default     = 70
}

variable "scale_out_cooldown_seconds" {
  description = "Short: react quickly to payment bursts."
  type        = number
  default     = 60
}

variable "scale_in_cooldown_seconds" {
  description = "Long: drain slowly so a burst that pauses for a minute does not cause thrashing."
  type        = number
  default     = 600
}

variable "queue_scaling" {
  description = <<-EOT
    Optional queue-depth scaling for workers.
      queue_name               - ingestion queue (CloudWatch dimension)
      backlog_per_task_target  - acceptable visible messages per running task
      burst_age_seconds        - age of oldest message that triggers an aggressive step scale-out
  EOT
  type = object({
    queue_name              = string
    backlog_per_task_target = number
    burst_age_seconds       = optional(number, 120)
  })
  default = null
}

variable "alb_request_scaling" {
  description = "Optional ALB request-count scaling: resource_label (<lb arn_suffix>/<tg arn_suffix>) and requests per target per minute."
  type = object({
    resource_label      = string
    requests_per_target = number
  })
  default = null
}

variable "alarm_topic_arn" {
  description = "SNS topic for service alarms."
  type        = string
  default     = null
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
  default     = {}
}
