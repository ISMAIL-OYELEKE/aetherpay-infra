variable "name" {
  description = "Name prefix for every resource, e.g. aetherpay-staging."
  type        = string
}

variable "vpc_cidr" {
  description = "Primary VPC block. The assessment mandates a single /20."
  type        = string
  default     = "10.24.0.0/20"

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0)) && tonumber(split("/", var.vpc_cidr)[1]) == 20
    error_message = "vpc_cidr must be a valid IPv4 /20 block."
  }
}

variable "azs" {
  description = "Exactly three Availability Zones."
  type        = list(string)

  validation {
    condition     = length(var.azs) == 3 && length(distinct(var.azs)) == 3
    error_message = "Provide exactly three distinct Availability Zones."
  }
}

variable "app_port" {
  description = "Container port exposed by the application tier behind the ALB."
  type        = number
  default     = 8080
}

variable "data_ports" {
  description = "Ports the isolated tier accepts from the application tier (Aurora PostgreSQL, Redis/Valkey)."
  type        = list(number)
  default     = [5432, 6379]
}

variable "interface_endpoints" {
  description = "AWS service short names that get Interface VPC Endpoints (PrivateLink) in the isolated tier."
  type        = list(string)
  default = [
    "ecr.api",
    "ecr.dkr",
    "logs",
    "monitoring",
    "secretsmanager",
    "kms",
    "sqs",
    "sts",
    "xray",
  ]
}

variable "enable_nat_gateway" {
  description = <<-EOT
    Provision one NAT Gateway per AZ in the public tier. Defaults to false because the
    application tier reaches every AWS dependency through VPC endpoints. Enable only if a
    partner callback genuinely needs internet egress, and pair it with nat_egress_cidrs.
  EOT
  type        = bool
  default     = false
}

variable "nat_egress_cidrs" {
  description = "Allow-listed destination CIDRs routed from the app tier via NAT (only when enable_nat_gateway = true). Never 0.0.0.0/0."
  type        = list(string)
  default     = []

  validation {
    condition     = !contains(var.nat_egress_cidrs, "0.0.0.0/0")
    error_message = "Arbitrary internet egress (0.0.0.0/0) is not allowed from the application tier."
  }
}

variable "flow_log_retention_days" {
  description = "Retention for VPC flow logs."
  type        = number
  default     = 365
}

variable "logs_kms_key_arn" {
  description = "CMK used to encrypt the flow log group."
  type        = string
}

variable "permissions_boundary_arn" {
  description = "Permissions boundary attached to every IAM role this module creates."
  type        = string
  default     = null
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
  default     = {}
}

variable "ingress_cidrs" {
  description = "Source CIDRs allowed to reach the ALB on 443. Narrow to partner ranges where they are published."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}
