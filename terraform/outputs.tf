# ─────────────────────────────────────────────────────────────────────────────
# Root outputs
# ─────────────────────────────────────────────────────────────────────────────

output "artifacts_bucket" {
  description = "S3 bucket for build artifacts"
  value       = aws_s3_bucket.artifacts.id
}

output "apt_repo_bucket" {
  description = "S3 bucket for APT repository"
  value       = aws_s3_bucket.apt_repo.id
}

output "yum_repo_bucket" {
  description = "S3 bucket for YUM repository"
  value       = aws_s3_bucket.yum_repo.id
}

output "ecr_repository_url" {
  description = "ECR repository URL for Docker build images"
  value       = aws_ecr_repository.pg_build.repository_url
}

output "codepipeline_role_arn" {
  description = "ARN of the CodePipeline IAM role"
  value       = aws_iam_role.codepipeline.arn
}

output "codebuild_role_arn" {
  description = "ARN of the CodeBuild IAM role"
  value       = aws_iam_role.codebuild.arn
}

output "eventbridge_role_arn" {
  description = "ARN of the EventBridge IAM role"
  value       = aws_iam_role.eventbridge.arn
}

output "pipeline_arns" {
  description = "Map of PG major version → CodePipeline ARN"
  value       = { for k, v in module.pg_pipeline : k => v.pipeline_arn }
}

output "eventbridge_rule_arns" {
  description = "Map of PG major version → EventBridge rule ARN"
  value       = { for k, v in module.pg_pipeline : k => v.eventbridge_rule_arn }
}

output "gpg_secret_arn" {
  description = "ARN of the GPG signing key secret in Secrets Manager"
  value       = aws_secretsmanager_secret.gpg_signing_key.arn
}
