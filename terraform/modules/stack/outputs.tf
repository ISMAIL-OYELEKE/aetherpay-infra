output "vpc_id" {
  description = "VPC ID."
  value       = module.networking.vpc_id
}

output "cidr_allocation" {
  description = "Per-tier CIDR allocation."
  value       = module.networking.cidr_allocation
}

output "alb_dns_name" {
  description = "ALB DNS name."
  value       = module.edge.alb_dns_name
}

output "alb_zone_id" {
  description = "ALB hosted zone ID."
  value       = module.edge.alb_zone_id
}

output "webhook_url" {
  description = "Public webhook base URL."
  value       = module.edge.webhook_url
}

output "ecr_repository_url" {
  description = "ECR repository to push images to."
  value       = module.compute.repository_url
}

output "ecs_cluster_name" {
  description = "ECS cluster name."
  value       = module.compute.cluster_name
}

output "ingestion_queue_url" {
  description = "Ingestion queue URL."
  value       = module.messaging.ingestion_queue_url
}

output "signing_secret_arns" {
  description = "Signing-key secret ARNs (values are never output)."
  value       = local.signing_secret_arns
}

output "signing_secret_replica_arns" {
  description = "Replicated signing-secret ARNs by region."
  value       = try(module.secrets[0].replica_secret_arns, {})
}

output "secretsmanager_vpce_id" {
  description = "Secrets Manager interface endpoint ID."
  value       = module.networking.interface_endpoint_ids["secretsmanager"]
}

output "secrets_kms_key_arn" {
  description = "Secrets CMK in this region."
  value       = module.security.secrets_kms_key_arn
}

output "db_global_cluster_identifier" {
  description = "Aurora Global cluster ID, emitted only once this region's writer exists (ordering token for secondaries)."
  value       = var.db.global_cluster_identifier
  depends_on  = [module.data]
}

output "db_endpoint" {
  description = "Aurora writer endpoint."
  value       = module.data.db_endpoint
}

output "alarm_topic_arn" {
  description = "SNS topic for operational alarms."
  value       = aws_sns_topic.alarms.arn
}

output "certificate_names" {
  description = "Names on this region's ALB certificate."
  value       = module.edge.certificate_names
}

output "certificate_validation_record_names" {
  description = "Certificate names whose DNS validation record this region owns."
  value       = module.edge.validation_record_names
}

output "db_master_credential_mode" {
  description = "How this region's Aurora master credential is provisioned."
  value       = module.data.db_master_credential_mode
}
