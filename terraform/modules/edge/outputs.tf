output "alb_arn" {
  description = "ALB ARN."
  value       = aws_lb.this.arn
}

output "alb_dns_name" {
  description = "ALB DNS name."
  value       = aws_lb.this.dns_name
}

output "alb_zone_id" {
  description = "ALB hosted zone ID (for Route 53 alias records)."
  value       = aws_lb.this.zone_id
}

output "target_group_arn" {
  description = "Application target group ARN."
  value       = aws_lb_target_group.app.arn
}

output "request_count_resource_label" {
  description = "Resource label for ALBRequestCountPerTarget scaling."
  value       = "${aws_lb.this.arn_suffix}/${aws_lb_target_group.app.arn_suffix}"
}

output "alb_arn_suffix" {
  description = "ALB ARN suffix (CloudWatch dimension)."
  value       = aws_lb.this.arn_suffix
}

output "webhook_url" {
  description = "Public webhook base URL."
  value       = "https://${var.domain_name}/webhooks/"
}

output "certificate_names" {
  description = "Names on the ALB certificate (regional name first, then SANs). Empty when an existing certificate_arn is used."
  value       = local.create_cert ? local.cert_names : []
}

output "validation_record_names" {
  description = "Certificate names whose DNS validation record this stack owns."
  value       = local.create_cert ? local.validation_record_names : []
}
