variable "name" {
  description = "Name prefix, e.g. aetherpay-staging."
  type        = string
}

variable "key_admin_arns" {
  description = "IAM principals allowed to administer (not use) the CMKs, e.g. the CI apply role and a break-glass role."
  type        = list(string)
  default     = []
}

variable "key_deletion_window_days" {
  description = "Waiting period before a scheduled CMK deletion takes effect."
  type        = number
  default     = 30
}

variable "waf_rate_limit" {
  description = "Maximum requests per IP per evaluation window before WAF blocks."
  type        = number
  default     = 1000
}

variable "waf_rate_window_seconds" {
  description = "WAF rate-based rule evaluation window (60, 120, 300 or 600)."
  type        = number
  default     = 300

  validation {
    condition     = contains([60, 120, 300, 600], var.waf_rate_window_seconds)
    error_message = "evaluation window must be one of 60, 120, 300, 600 seconds."
  }
}

variable "waf_log_retention_days" {
  description = "Retention for WAF logs."
  type        = number
  default     = 365
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
  default     = {}
}
