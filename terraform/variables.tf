variable "aws_region" {
  description = "AWS region for all resources"
  type        = string
  default     = "ap-south-1"
}

variable "aws_account_id" {
  description = "AWS account ID (12-digit string)"
  type        = string
}

variable "github_connection_arn" {
  description = "ARN of the CodeStar Connections connection to GitHub"
  type        = string
}

variable "packaging_repo" {
  description = "GitHub full repo ID for pg-packaging (org/repo)"
  type        = string
  default     = "pg-platform/pg-packaging"
}

variable "platform_repo" {
  description = "GitHub full repo ID for pg-platform (org/repo)"
  type        = string
  default     = "pg-platform/pg-platform"
}

variable "artifacts_bucket_name" {
  description = "S3 bucket for build artifacts"
  type        = string
  default     = "pg-platform-cicd-artifacts"
}

variable "apt_bucket_name" {
  description = "S3 bucket serving the APT repository"
  type        = string
  default     = "pg-platform-apt-repo"
}

variable "yum_bucket_name" {
  description = "S3 bucket serving the YUM repository"
  type        = string
  default     = "pg-platform-yum-repo"
}

variable "ecr_repository_name" {
  description = "ECR repository name for Docker build images"
  type        = string
  default     = "pg-platform/pg-build"
}

variable "gpg_key_id" {
  description = "GPG key ID (fingerprint) used for package signing"
  type        = string
  default     = ""
}

variable "gpg_private_key_b64" {
  description = "Base64-encoded GPG private key. Stored in Secrets Manager."
  type        = string
  default     = ""
  sensitive   = true
}

variable "pulp_url" {
  description = "Pulp server URL. Leave empty to disable."
  type        = string
  default     = ""
}

variable "pulp_password" {
  description = "Pulp API password. Only used if pulp_url is set."
  type        = string
  default     = ""
  sensitive   = true
}

variable "cloudfront_distribution_id" {
  description = "CloudFront distribution ID for CDN invalidation. Leave empty to skip."
  type        = string
  default     = ""
}

variable "pg_versions" {
  description = "PostgreSQL major versions to create pipelines for"
  type        = list(string)
  default     = ["14", "15", "16", "17"]
}

variable "build_env" {
  description = "Default build environment (staging or production)"
  type        = string
  default     = "staging"
}

variable "codebuild_compute_type" {
  description = "Compute type for build CodeBuild projects"
  type        = string
  default     = "BUILD_GENERAL1_LARGE"
}

variable "codebuild_image" {
  description = "Standard CodeBuild image used by parse-tag and repo-updater"
  type        = string
  default     = "aws/codebuild/standard:7.0"
}

variable "tags" {
  description = "Tags applied to all resources"
  type        = map(string)
  default = {
    Project   = "pg-platform-packaging"
    ManagedBy = "terraform"
  }
}
