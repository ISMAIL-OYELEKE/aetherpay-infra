output "vpc_id" {
  description = "VPC ID."
  value       = aws_vpc.this.id
}

output "vpc_cidr" {
  description = "VPC CIDR block."
  value       = aws_vpc.this.cidr_block
}

output "public_subnet_ids" {
  description = "Public tier subnet IDs (ALB, NAT)."
  value       = aws_subnet.public[*].id
}

output "app_subnet_ids" {
  description = "Private application tier subnet IDs."
  value       = aws_subnet.app[*].id
}

output "isolated_subnet_ids" {
  description = "Isolated database/vault tier subnet IDs."
  value       = aws_subnet.isolated[*].id
}

output "cidr_allocation" {
  description = "Per-tier CIDR allocation, in AZ order."
  value = {
    public   = local.public_cidrs
    app      = local.app_cidrs
    isolated = local.isolated_cidrs
  }
}

output "app_route_table_ids" {
  description = "Application tier route tables."
  value       = aws_route_table.app[*].id
}

output "isolated_route_table_id" {
  description = "Isolated tier route table."
  value       = aws_route_table.isolated.id
}

output "endpoint_security_group_id" {
  description = "Security group attached to interface endpoints."
  value       = aws_security_group.endpoints.id
}

output "interface_endpoint_ids" {
  description = "Map of service short name => interface endpoint ID. Used in aws:SourceVpce IAM conditions."
  value       = { for k, v in aws_vpc_endpoint.interface : k => v.id }
}

output "s3_gateway_endpoint_id" {
  description = "S3 gateway endpoint ID."
  value       = aws_vpc_endpoint.s3.id
}

output "s3_prefix_list_id" {
  description = "Managed prefix list for S3 (for security group egress)."
  value       = aws_vpc_endpoint.s3.prefix_list_id
}

output "dynamodb_gateway_endpoint_id" {
  description = "DynamoDB gateway endpoint ID."
  value       = aws_vpc_endpoint.dynamodb.id
}

output "dynamodb_prefix_list_id" {
  description = "Managed prefix list for DynamoDB (for security group egress)."
  value       = aws_vpc_endpoint.dynamodb.prefix_list_id
}

output "security_group_ids" {
  description = "Security groups by role: alb, app, db, cache, endpoints."
  value = {
    alb       = aws_security_group.alb.id
    app       = aws_security_group.app.id
    db        = aws_security_group.db.id
    cache     = aws_security_group.cache.id
    endpoints = aws_security_group.endpoints.id
  }
}
