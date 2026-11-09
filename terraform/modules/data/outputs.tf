output "db_cluster_arn" {
  description = "Aurora cluster ARN."
  value       = aws_rds_cluster.this.arn
}

output "db_cluster_resource_id" {
  description = "Aurora cluster resource ID (used in rds-db:connect ARNs)."
  value       = aws_rds_cluster.this.cluster_resource_id
}

output "db_endpoint" {
  description = "Aurora writer endpoint. Read from the resource, never constructed."
  value       = aws_rds_cluster.this.endpoint
}

output "db_reader_endpoint" {
  description = "Aurora reader endpoint."
  value       = aws_rds_cluster.this.reader_endpoint
}

output "db_name" {
  description = "Database name."
  value       = var.db_name
}

output "db_master_secret_arn" {
  description = "ARN of the RDS-managed master secret (break-glass only). The value is never exposed."
  value       = try(aws_rds_cluster.this.master_user_secret[0].secret_arn, null)
}

output "cache_primary_endpoint" {
  description = "ElastiCache primary endpoint. Read from the resource, never constructed."
  value       = aws_elasticache_replication_group.this.primary_endpoint_address
}

output "cache_replication_group_arn" {
  description = "ElastiCache replication group ARN."
  value       = aws_elasticache_replication_group.this.arn
}

output "cache_replication_group_id" {
  description = "ElastiCache replication group ID (used to sign IAM auth tokens)."
  value       = aws_elasticache_replication_group.this.id
}

output "cache_user_arn" {
  description = "ElastiCache IAM user ARN."
  value       = aws_elasticache_user.workload.arn
}

output "cache_user_name" {
  description = "ElastiCache IAM user name."
  value       = aws_elasticache_user.workload.user_name
}
