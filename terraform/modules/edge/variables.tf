variable "name" {
  description = "Name prefix, e.g. aetherpay-staging."
  type        = string
}

variable "vpc_id" {
  description = "VPC ID."
  type        = string
}

variable "public_subnet_ids" {
  description = "Public tier subnets for the ALB."
  type        = list(string)
}

variable "alb_security_group_id" {
  description = "ALB security group."
  type        = string
}

variable "app_port" {
  description = "Target port on the application tier."
  type        = number
  default     = 8080
}

variable "health_check_path" {
  description = "Target group health check path."
  type        = string
  default     = "/healthz"
}

variable "waf_web_acl_arn" {
  description = "Regional WAF web ACL to associate."
  type        = string
}

variable "domain_name" {
  description = "FQDN for the webhook endpoint, e.g. webhooks.staging.example.com."
  type        = string
}

variable "hosted_zone_id" {
  description = "Route 53 public hosted zone used for DNS validation and the alias record. Null when certificate_arn is supplied."
  type        = string
  default     = null
}

variable "certificate_arn" {
  description = "Existing ACM certificate ARN. When null, a DNS-validated certificate is created in hosted_zone_id."
  type        = string
  default     = null
}

variable "ssl_policy" {
  description = "ALB TLS policy. Default allows TLS 1.3 only."
  type        = string
  default     = "ELBSecurityPolicy-TLS13-1-3-2021-06"
}

variable "deletion_protection" {
  description = "Protect the ALB from deletion."
  type        = bool
  default     = true
}

variable "access_log_retention_days" {
  description = "Days to keep ALB access logs."
  type        = number
  default     = 90
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
  default     = {}
}
