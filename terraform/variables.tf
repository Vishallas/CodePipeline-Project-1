# ─────────────────────────────────────────────────────────────────────────────
# Root variables — set these in terraform.tfvars or via environment variables
# ─────────────────────────────────────────────────────────────────────────────

variable "aws_region" {
  description = "AWS region for all resources"
  type        = string
  default     = "ap-south-1"
}

variable "aws_account_id" {
  description = "AWS account ID (12-digit string)"
  type        = string
}

# ── GitHub / CodeStar ──────────────────────────────────────────────────────

variable "github_connection_arn" {
  description = <<-EOT
    ARN of the CodeStar Connections connection to GitHub.
    Create via: aws codestar-connections create-connection --provider-type GitHub
    Then complete the OAuth handshake in AWS Console → Developer Tools → Connections.
  EOT
  type = string
}

variable "packaging_repo" {
  description = "GitHub full repo ID for mydbops-pg-packaging (org/repo)"
  type        = string
  default     = "mydbops/mydbops-pg-packaging"
}

variable "platform_repo" {
  description = "GitHub full repo ID for mydbops-pg-platform (org/repo)"
  type        = string
  default     = "mydbops/mydbops-pg-platform"
}

# ── S3 ────────────────────────────────────────────────────────────────────

variable "artifacts_bucket_name" {
  description = "S3 bucket for build artifacts (packages, SHA256 sidecars)"
  type        = string
  default     = "mydbops-cicd-artifacts"
}

variable "apt_bucket_name" {
  description = "S3 bucket serving the APT (Debian/Ubuntu) repository"
  type        = string
  default     = "mydbops-apt-repo"
}

variable "yum_bucket_name" {
  description = "S3 bucket serving the YUM (EPEL/Fedora) repository"
  type        = string
  default     = "mydbops-yum-repo"
}

# ── ECR ───────────────────────────────────────────────────────────────────

variable "ecr_repository_name" {
  description = "ECR repository name for Docker build images"
  type        = string
  default     = "mydbops/pg-build"
}

# ── GPG signing ───────────────────────────────────────────────────────────

variable "gpg_key_id" {
  description = "GPG key ID (fingerprint) used for package signing"
  type        = string
  default     = ""
}

variable "gpg_private_key_b64" {
  description = <<-EOT
    Base64-encoded GPG private key for package signing.
    Generate: gpg --export-secret-keys --armor YOUR_KEY_ID | base64 -w0
    This is stored in Secrets Manager — provide it once at setup, then rotate via Console.
  EOT
  type      = string
  default   = ""
  sensitive = true
}

# ── Pulp (optional) ───────────────────────────────────────────────────────

variable "pulp_url" {
  description = "Pulp server URL. Leave empty to disable Pulp integration."
  type        = string
  default     = ""
}

variable "pulp_password" {
  description = "Pulp API password. Only used if pulp_url is set."
  type        = string
  default     = ""
  sensitive   = true
}

# ── CloudFront ────────────────────────────────────────────────────────────

variable "cloudfront_distribution_id" {
  description = "CloudFront distribution ID for APT/YUM repo CDN invalidation. Leave empty to skip invalidation."
  type        = string
  default     = ""
}

# ── Pipeline ──────────────────────────────────────────────────────────────

variable "pg_versions" {
  description = <<-EOT
    List of active PostgreSQL major versions to create pipelines for.
    Each entry creates one CodePipeline + one EventBridge rule.
    Remove a version to disable its pipeline (use eol.sh first).
  EOT
  type    = list(string)
  default = ["14", "15", "16", "17"]
}

variable "build_env" {
  description = "Default build environment tag written to SSM (staging or production)"
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
  description = "Tags to apply to all resources"
  type        = map(string)
  default = {
    Project   = "mydbops-pg-packaging"
    ManagedBy = "terraform"
  }
}
