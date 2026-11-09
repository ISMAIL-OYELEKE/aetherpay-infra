output "signing_secret_arns" {
  description = "Map of signing key name => secret ARN."
  value       = { for k, v in aws_secretsmanager_secret.signing : k => v.arn }
}

output "rotation_function_arn" {
  description = "Rotation Lambda ARN."
  value       = aws_lambda_function.rotation.arn
}

output "replica_secret_arns" {
  description = "Map of region => (signing key name => replicated secret ARN)."
  value = {
    for region, _ in var.replica_regions : region => {
      for k, v in aws_secretsmanager_secret.signing : k => replace(v.arn, ":${data.aws_region.current.region}:", ":${region}:")
    }
  }
}
