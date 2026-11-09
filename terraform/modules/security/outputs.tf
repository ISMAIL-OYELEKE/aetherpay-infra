output "kms_key_arns" {
  description = "Map of purpose (secrets, data, logs) => CMK ARN."
  value       = { for k, v in aws_kms_key.this : k => v.arn }
}

output "secrets_kms_key_arn" {
  description = "CMK for Secrets Manager."
  value       = aws_kms_key.this["secrets"].arn
}

output "data_kms_key_arn" {
  description = "CMK for data stores and queues."
  value       = aws_kms_key.this["data"].arn
}

output "logs_kms_key_arn" {
  description = "CMK for CloudWatch Logs."
  value       = aws_kms_key.this["logs"].arn
}

output "waf_web_acl_arn" {
  description = "Regional WAF web ACL to associate with the ALB."
  value       = aws_wafv2_web_acl.this.arn
}
