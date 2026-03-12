variable "pg_major" {
  description = "PostgreSQL major version number (e.g. '14', '16')"
  type        = string
}

variable "aws_region" {
  type = string
}

variable "aws_account_id" {
  type = string
}

variable "artifacts_bucket" {
  description = "S3 bucket name for CodePipeline artifacts"
  type        = string
}

variable "github_connection_arn" {
  description = "ARN of CodeStar Connections GitHub connection"
  type        = string
}

variable "packaging_repo" {
  description = "GitHub full repo ID for mydbops-pg-packaging"
  type        = string
}

variable "platform_repo" {
  description = "GitHub full repo ID for mydbops-pg-platform"
  type        = string
}

variable "codepipeline_role_arn" {
  description = "IAM role ARN for CodePipeline"
  type        = string
}

variable "eventbridge_role_arn" {
  description = "IAM role ARN for EventBridge to start the pipeline"
  type        = string
}

variable "codebuild_parse_tag_project" {
  type = string
}

variable "codebuild_ubuntu_amd64_project" {
  type = string
}

variable "codebuild_ubuntu_arm64_project" {
  type = string
}

variable "codebuild_rpm_amd64_project" {
  type = string
}

variable "codebuild_rpm_arm64_project" {
  type = string
}

variable "codebuild_test_project" {
  type = string
}

variable "codebuild_repo_updater_project" {
  type = string
}

variable "tags" {
  type    = map(string)
  default = {}
}
