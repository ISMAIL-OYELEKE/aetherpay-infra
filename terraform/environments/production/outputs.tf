output "global_webhook_url" {
  description = "Partner-facing webhook URL (ARC failover record)."
  value       = "https://${var.global_domain_name}/webhooks/"
}

output "arc_cluster_endpoints" {
  description = "ARC data-plane endpoints: copy into the offline runbook."
  value       = module.dr_routing.cluster_endpoints
}

output "arc_routing_control_arns" {
  description = "Routing controls used by the failover runbook."
  value       = module.dr_routing.routing_control_arns
}

output "ledger_table_name" {
  description = "Ledger journal table."
  value       = module.ledger.table_name
}

output "primary_alb_dns_name" {
  description = "Primary ALB."
  value       = module.primary.alb_dns_name
}

output "secondary_alb_dns_name" {
  description = "Secondary ALB."
  value       = module.secondary.alb_dns_name
}
