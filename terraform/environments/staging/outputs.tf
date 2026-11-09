output "webhook_url" {
  description = "Public webhook base URL."
  value       = module.stack.webhook_url
}

output "alb_dns_name" {
  description = "ALB DNS name."
  value       = module.stack.alb_dns_name
}

output "cidr_allocation" {
  description = "CIDR allocation by tier."
  value       = module.stack.cidr_allocation
}

output "ecs_cluster_name" {
  description = "ECS cluster."
  value       = module.stack.ecs_cluster_name
}

output "ledger_table_name" {
  description = "Ledger journal table."
  value       = module.ledger.table_name
}

output "signing_secret_arns" {
  description = "Signing-key secret ARNs (never values)."
  value       = module.stack.signing_secret_arns
}
