output "state_bucket" {
  description = "Remote state bucket. Set as the TF_STATE_BUCKET repository variable."
  value       = aws_s3_bucket.state.id
}

output "state_kms_key_arn" {
  description = "State CMK. Set as the TF_STATE_KMS_KEY_ARN repository variable."
  value       = aws_kms_key.state.arn
}

output "plan_role_arns" {
  description = "Per-environment plan role ARNs (AWS_PLAN_ROLE_ARN environment variable)."
  value       = { for k, v in aws_iam_role.plan : k => v.arn }
}

output "apply_role_arns" {
  description = "Per-environment apply role ARNs (AWS_APPLY_ROLE_ARN environment variable)."
  value       = { for k, v in aws_iam_role.apply : k => v.arn }
}

output "image_push_role_arn" {
  description = "Role that builds and pushes the application image."
  value       = aws_iam_role.image_push.arn
}

output "ecr_repository_url" {
  description = "Application image repository."
  value       = aws_ecr_repository.app.repository_url
}

output "ecr_repository_arn" {
  description = "Application image repository ARN (pass to environments as ecr_repository_arn)."
  value       = aws_ecr_repository.app.arn
}

output "workload_permissions_boundary_arn" {
  description = "Boundary every workload role must carry."
  value       = aws_iam_policy.workload_boundary.arn
}
