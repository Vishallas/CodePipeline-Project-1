# ─────────────────────────────────────────────────────────────────────────────
# mydbops-pg-platform — Root Terraform module
#
# Creates all shared infrastructure once, then instantiates one pg-pipeline
# module per active PG major version.
#
# Usage:
#   cp terraform.tfvars.example terraform.tfvars
#   # fill in terraform.tfvars
#   terraform init
#   terraform apply
# ─────────────────────────────────────────────────────────────────────────────

terraform {
  required_version = ">= 1.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # Recommended: store state in S3 + DynamoDB lock
  # backend "s3" {
  #   bucket         = "mydbops-terraform-state"
  #   key            = "pg-packaging/terraform.tfstate"
  #   region         = "ap-south-1"
  #   dynamodb_table = "mydbops-terraform-lock"
  #   encrypt        = true
  # }
}

provider "aws" {
  region = var.aws_region
}

# ── Local helpers ─────────────────────────────────────────────────────────────

locals {
  codepipeline_role_name = "mydbops-postgresql-packaging-codepipeline-role"
  codebuild_role_name    = "mydbops-postgresql-packaging-codebuild-role"
  eventbridge_role_name  = "mydbops-postgresql-packaging-eventbridge-role"
  cloudfront_param = var.cloudfront_distribution_id == null ? {} : {
    cloudfront = var.cloudfront_distribution_id
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# S3 Buckets
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_s3_bucket" "artifacts" {
  bucket = var.artifacts_bucket_name
  tags   = var.tags
}

resource "aws_s3_bucket_versioning" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_public_access_block" "artifacts" {
  bucket                  = aws_s3_bucket.artifacts.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket" "apt_repo" {
  bucket = var.apt_bucket_name
  tags   = var.tags
}

resource "aws_s3_bucket_public_access_block" "apt_repo" {
  bucket                  = aws_s3_bucket.apt_repo.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket" "yum_repo" {
  bucket = var.yum_bucket_name
  tags   = var.tags
}

resource "aws_s3_bucket_public_access_block" "yum_repo" {
  bucket                  = aws_s3_bucket.yum_repo.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ─────────────────────────────────────────────────────────────────────────────
# ECR Repository
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_ecr_repository" "pg_build" {
  name                 = var.ecr_repository_name
  image_tag_mutability = "MUTABLE"
  force_delete         = false

  image_scanning_configuration { scan_on_push = true }

  tags = var.tags
}

resource "aws_ecr_lifecycle_policy" "pg_build" {
  repository = aws_ecr_repository.pg_build.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep last 10 images per tag prefix"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 30
      }
      action = { type = "expire" }
    }]
  })
}

# ─────────────────────────────────────────────────────────────────────────────
# IAM Roles
# ─────────────────────────────────────────────────────────────────────────────

# ── CodePipeline role ─────────────────────────────────────────────────────────

resource "aws_iam_role" "codepipeline" {
  name = local.codepipeline_role_name
  tags = var.tags

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "codepipeline.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "codepipeline" {
  name = "mydbops-postgresql-packaging-codepipeline-policy"
  role = aws_iam_role.codepipeline.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "CodeBuildAccess"
        Effect = "Allow"
        Action = ["codebuild:StartBuild", "codebuild:BatchGetBuilds"]
        Resource = "*"
      },
      {
        Sid    = "ArtifactBucketAccess"
        Effect = "Allow"
        Action = ["s3:GetObject", "s3:PutObject", "s3:GetBucketVersioning"]
        Resource = [
          aws_s3_bucket.artifacts.arn,
          "${aws_s3_bucket.artifacts.arn}/*"
        ]
      },
      {
        Sid    = "ReadSSM"
        Effect = "Allow"
        Action = ["ssm:GetParameter", "ssm:GetParameters"]
        Resource = "arn:aws:ssm:${var.aws_region}:${var.aws_account_id}:parameter/mydbops/cicd/*"
      },
      {
        Sid      = "GitHubConnection"
        Effect   = "Allow"
        Action   = ["codestar-connections:UseConnection"]
        Resource = var.github_connection_arn
      }
    ]
  })
}

# ── CodeBuild role ────────────────────────────────────────────────────────────

resource "aws_iam_role" "codebuild" {
  name = local.codebuild_role_name
  tags = var.tags

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "codebuild.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "codebuild" {
  name = "mydbops-postgresql-packaging-codebuild-policy"
  role = aws_iam_role.codebuild.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ArtifactsBucket"
        Effect = "Allow"
        Action = ["s3:PutObject", "s3:GetObject", "s3:ListBucket", "s3:DeleteObject"]
        Resource = [
          aws_s3_bucket.artifacts.arn,
          "${aws_s3_bucket.artifacts.arn}/*"
        ]
      },
      {
        Sid    = "RepoBuckets"
        Effect = "Allow"
        Action = ["s3:PutObject", "s3:GetObject", "s3:ListBucket"]
        Resource = [
          aws_s3_bucket.apt_repo.arn,
          "${aws_s3_bucket.apt_repo.arn}/*",
          aws_s3_bucket.yum_repo.arn,
          "${aws_s3_bucket.yum_repo.arn}/*"
        ]
      },
      {
        Sid    = "PullBuildImages"
        Effect = "Allow"
        Action = [
          "ecr:GetAuthorizationToken",
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage"
        ]
        Resource = "*"
      },
      {
        # Required for CODEBUILD_CLONE_REF: CodeBuild authenticates with GitHub
        # via the connection when running `git fetch --tags` inside the build.
        Sid    = "GitHubCloneRef"
        Effect = "Allow"
        Action = [
          "codeconnections:UseConnection",
          "codestar-connections:UseConnection"
        ]
        Resource = var.github_connection_arn
      },
      {
        Sid    = "SSMRead"
        Effect = "Allow"
        Action = ["ssm:GetParameter", "ssm:GetParameters"]
        Resource = "arn:aws:ssm:${var.aws_region}:${var.aws_account_id}:parameter/mydbops/cicd/*"
      },
      {
        # Only ParseTag project needs PutParameter — same role for simplicity
        Sid    = "SSMWrite"
        Effect = "Allow"
        Action = ["ssm:PutParameter"]
        Resource = "arn:aws:ssm:${var.aws_region}:${var.aws_account_id}:parameter/mydbops/cicd/build/*"
      },
      {
        Sid      = "Secrets"
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = "arn:aws:secretsmanager:${var.aws_region}:${var.aws_account_id}:secret:mydbops/cicd/*"
      },
      {
        Sid    = "Logs"
        Effect = "Allow"
        Action = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "arn:aws:logs:${var.aws_region}:${var.aws_account_id}:log-group:/aws/codebuild/mydbops-*"
      },
      {
        Sid      = "CloudFrontInvalidation"
        Effect   = "Allow"
        Action   = ["cloudfront:CreateInvalidation"]
        Resource = var.cloudfront_distribution_id != "" ? (
          "arn:aws:cloudfront::${var.aws_account_id}:distribution/${var.cloudfront_distribution_id}"
        ) : "*"
      }
    ]
  })
}

# ── EventBridge role ──────────────────────────────────────────────────────────

resource "aws_iam_role" "eventbridge" {
  name = local.eventbridge_role_name
  tags = var.tags

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "events.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "eventbridge" {
  name = "mydbops-postgresql-packaging-eventbridge-policy"
  role = aws_iam_role.eventbridge.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["codepipeline:StartPipelineExecution"]
      Resource = "arn:aws:codepipeline:${var.aws_region}:${var.aws_account_id}:mydbops-pkg-pg*"
    }]
  })
}

# ─────────────────────────────────────────────────────────────────────────────
# SSM Parameters — static, set once
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_ssm_parameter" "s3_bucket" {
  name  = "/mydbops/cicd/build/S3_BUCKET"
  type  = "String"
  value = var.artifacts_bucket_name
  tags  = var.tags
}

resource "aws_ssm_parameter" "build_env" {
  name  = "/mydbops/cicd/build/BUILD_ENV"
  type  = "String"
  value = var.build_env
  tags  = var.tags
}

resource "aws_ssm_parameter" "ecr_account_id" {
  name  = "/mydbops/cicd/ecr/account_id"
  type  = "String"
  value = var.aws_account_id
  tags  = var.tags
}

resource "aws_ssm_parameter" "ecr_region" {
  name  = "/mydbops/cicd/ecr/region"
  type  = "String"
  value = var.aws_region
  tags  = var.tags
}

resource "aws_ssm_parameter" "gpg_key_id" {
  name  = "/mydbops/cicd/gpg/key_id"
  type  = "String"
  value = var.gpg_key_id
  tags  = var.tags
}

# resource "aws_ssm_parameter" "cloudfront_distribution_id" {
#   count = var.cloudfront_distribution_id != null ? 1 : 0 
#   name  = "/mydbops/cicd/cloudfront/distribution_id"
#   type  = "String"
#   value = var.cloudfront_distribution_id
#   tags  = var.tags
# }

# resource "aws_ssm_parameter" "cloudfront_distribution_id" {
#   for_each = local.cloudfront_param

#   name  = "/mydbops/cicd/cloudfront/distribution_id"
#   type  = "String"
#   value = each.value

#   tags = var.tags
# }


resource "aws_ssm_parameter" "cloudfront_distribution_id" {
  count = (
    var.cloudfront_distribution_id != null &&
    var.cloudfront_distribution_id != ""
  ) ? 1 : 0

  name      = "/mydbops/cicd/cloudfront/distribution_id"
  type      = "String"
  value     = var.cloudfront_distribution_id
  overwrite = true

  tags = var.tags
}

# Placeholder parameters for dynamic vars written by ParseTag at runtime.
# These are overwritten on every pipeline run — initial value is a placeholder.
resource "aws_ssm_parameter" "package_name" {
  name      = "/mydbops/cicd/build/PACKAGE_NAME"
  type      = "String"
  value     = "placeholder"
  overwrite = true
  tags      = var.tags

  lifecycle { ignore_changes = [value] }
}

resource "aws_ssm_parameter" "package_version" {
  name      = "/mydbops/cicd/build/PACKAGE_VERSION"
  type      = "String"
  value     = "placeholder"
  overwrite = true
  tags      = var.tags

  lifecycle { ignore_changes = [value] }
}

resource "aws_ssm_parameter" "package_revision" {
  name      = "/mydbops/cicd/build/PACKAGE_REVISION"
  type      = "String"
  value     = "placeholder"
  overwrite = true
  tags      = var.tags

  lifecycle { ignore_changes = [value] }
}

resource "aws_ssm_parameter" "pg_major" {
  name      = "/mydbops/cicd/build/PG_MAJOR"
  type      = "String"
  value     = "placeholder"
  overwrite = true
  tags      = var.tags

  lifecycle { ignore_changes = [value] }
}

resource "aws_ssm_parameter" "git_tag" {
  name      = "/mydbops/cicd/build/GIT_TAG"
  type      = "String"
  value     = "placeholder"
  overwrite = true
  tags      = var.tags

  lifecycle { ignore_changes = [value] }
}

resource "aws_ssm_parameter" "is_rc" {
  name      = "/mydbops/cicd/build/IS_RC"
  type      = "String"
  value     = "false"
  overwrite = true
  tags      = var.tags

  lifecycle { ignore_changes = [value] }
}

# ─────────────────────────────────────────────────────────────────────────────
# Secrets Manager
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_secretsmanager_secret" "gpg_signing_key" {
  name                    = "mydbops/cicd/gpg-signing-key-1"
  description             = "Base64-encoded GPG private key for package signing"
  recovery_window_in_days = 0
  tags                    = var.tags
}

resource "aws_secretsmanager_secret_version" "gpg_signing_key" {
  secret_id     = aws_secretsmanager_secret.gpg_signing_key.id
  secret_string = var.gpg_private_key_b64 != "" ? var.gpg_private_key_b64 : "REPLACE_WITH_BASE64_GPG_KEY"

  lifecycle { ignore_changes = [secret_string] }
}

resource "aws_secretsmanager_secret" "pulp_password" {
  count                   = var.pulp_url != "" ? 1 : 0
  name                    = "mydbops/cicd/pulp-password"
  description             = "Pulp API password for optional Pulp integration"
  recovery_window_in_days = 7
  tags                    = var.tags
}

resource "aws_secretsmanager_secret_version" "pulp_password" {
  count         = var.pulp_url != "" ? 1 : 0
  secret_id     = aws_secretsmanager_secret.pulp_password[0].id
  secret_string = var.pulp_password != "" ? var.pulp_password : "REPLACE_WITH_PULP_PASSWORD"

  lifecycle { ignore_changes = [secret_string] }
}

# ─────────────────────────────────────────────────────────────────────────────
# CodeBuild Projects — shared across all PG pipelines
# ─────────────────────────────────────────────────────────────────────────────

# ── ParseTag (Stage 2) ────────────────────────────────────────────────────────

resource "aws_codebuild_project" "parse_tag" {
  name          = "mydbops-parse-tag"
  description   = "Parses git tag, validates METADATA.yml, writes SSM, exports pipeline vars"
  service_role  = aws_iam_role.codebuild.arn
  build_timeout = 5

  artifacts { type = "CODEPIPELINE" }

  environment {
    type            = "LINUX_CONTAINER"
    compute_type    = "BUILD_GENERAL1_SMALL"
    image           = var.codebuild_image
    privileged_mode = false
  }

  source {
    type      = "CODEPIPELINE"
    buildspec = "buildspec/buildspec-parse-tag.yml"
  }

  logs_config {
    cloudwatch_logs {
      group_name  = "/aws/codebuild/mydbops-parse-tag"
      stream_name = ""
    }
  }

  tags = var.tags
}

# ── Ubuntu amd64 (Stage 3) ────────────────────────────────────────────────────

resource "aws_codebuild_project" "build_ubuntu_amd64" {
  name          = "mydbops-build-ubuntu-amd64"
  description   = "Builds .deb packages for Ubuntu 20/22/24 on x86_64"
  service_role  = aws_iam_role.codebuild.arn
  build_timeout = 60

  artifacts { type = "CODEPIPELINE" }

  environment {
    type            = "LINUX_CONTAINER"
    compute_type    = var.codebuild_compute_type
    image           = var.codebuild_image
    privileged_mode = true
  }

  source {
    type      = "CODEPIPELINE"
    buildspec = "buildspec/buildspec-ubuntu-amd64.yml"
  }

  logs_config {
    cloudwatch_logs {
      group_name  = "/aws/codebuild/mydbops-build-ubuntu-amd64"
      stream_name = ""
    }
  }

  tags = var.tags
}

# ── Ubuntu arm64 (Stage 3) ────────────────────────────────────────────────────

resource "aws_codebuild_project" "build_ubuntu_arm64" {
  name          = "mydbops-build-ubuntu-arm64"
  description   = "Builds .deb packages for Ubuntu 22/24 on aarch64"
  service_role  = aws_iam_role.codebuild.arn
  build_timeout = 60

  artifacts { type = "CODEPIPELINE" }

  environment {
    type            = "ARM_CONTAINER"
    compute_type    = "BUILD_GENERAL1_LARGE"
    # AWS publishes no Ubuntu image for ARM_CONTAINER — only Amazon Linux is available.
    # The buildspec installs host tools via yum; the actual DEB build runs inside
    # the Ubuntu arm64 Docker image pulled from ECR, so the host OS doesn't matter.
    image           = "aws/codebuild/amazonlinux-aarch64-standard:3.0"
    privileged_mode = true
  }

  source {
    type      = "CODEPIPELINE"
    buildspec = "buildspec/buildspec-ubuntu-arm64.yml"
  }

  logs_config {
    cloudwatch_logs {
      group_name  = "/aws/codebuild/mydbops-build-ubuntu-arm64"
      stream_name = ""
    }
  }

  tags = var.tags
}

# ── RPM amd64 (Stage 3) ───────────────────────────────────────────────────────

resource "aws_codebuild_project" "build_rpm_amd64" {
  name          = "mydbops-build-rpm-amd64"
  description   = "Builds .rpm packages for EPEL 8/9/10 + Fedora 42/43 on x86_64"
  service_role  = aws_iam_role.codebuild.arn
  build_timeout = 60

  artifacts { type = "CODEPIPELINE" }

  environment {
    type            = "LINUX_CONTAINER"
    compute_type    = var.codebuild_compute_type
    # Amazon Linux 2023 x86_64 — buildspec uses yum.
    # standard:7.0 is Ubuntu (no yum) and would fail at INSTALL phase.
    # Image name: "amazonlinux-x86_64" not "amazonlinux2023-x86_64" (AWS naming convention).
    image           = "aws/codebuild/amazonlinux-x86_64-standard:5.0"
    privileged_mode = true
  }

  source {
    type      = "CODEPIPELINE"
    buildspec = "buildspec/buildspec-rpm-amd64.yml"
  }

  logs_config {
    cloudwatch_logs {
      group_name  = "/aws/codebuild/mydbops-build-rpm-amd64"
      stream_name = ""
    }
  }

  tags = var.tags
}

# ── RPM arm64 (Stage 3) ───────────────────────────────────────────────────────

resource "aws_codebuild_project" "build_rpm_arm64" {
  name          = "mydbops-build-rpm-arm64"
  description   = "Builds .rpm packages for EPEL 8/9 on aarch64"
  service_role  = aws_iam_role.codebuild.arn
  build_timeout = 60

  artifacts { type = "CODEPIPELINE" }

  environment {
    type            = "ARM_CONTAINER"
    compute_type    = "BUILD_GENERAL1_LARGE"
    # Amazon Linux 2023 aarch64 — matches the yum-based buildspec.
    # amazonlinux2-aarch64-standard:3.0 (AL2) was EOL as of June 2025.
    # Image name: "amazonlinux-aarch64" not "amazonlinux2023-aarch64" (AWS naming convention).
    image           = "aws/codebuild/amazonlinux-aarch64-standard:3.0"
    privileged_mode = true
  }

  source {
    type      = "CODEPIPELINE"
    buildspec = "buildspec/buildspec-rpm-arm64.yml"
  }

  logs_config {
    cloudwatch_logs {
      group_name  = "/aws/codebuild/mydbops-build-rpm-arm64"
      stream_name = ""
    }
  }

  tags = var.tags
}

# ── Test install (Stage 4) ────────────────────────────────────────────────────

resource "aws_codebuild_project" "test_install" {
  name          = "mydbops-test-install"
  description   = "Install-tests packages from S3 staging path in clean containers"
  service_role  = aws_iam_role.codebuild.arn
  build_timeout = 30

  artifacts { type = "CODEPIPELINE" }

  environment {
    type            = "LINUX_CONTAINER"
    compute_type    = "BUILD_GENERAL1_MEDIUM"
    image           = var.codebuild_image
    privileged_mode = true
  }

  source {
    type      = "CODEPIPELINE"
    buildspec = "buildspec/buildspec-test.yml"
  }

  logs_config {
    cloudwatch_logs {
      group_name  = "/aws/codebuild/mydbops-test-install"
      stream_name = ""
    }
  }

  tags = var.tags
}

# ── Repo updater (Stage 5 + Stage 7) ─────────────────────────────────────────

module "repo_updater" {
  source = "./modules/repo-updater"

  codebuild_role_arn = aws_iam_role.codebuild.arn
  codebuild_image    = var.codebuild_image
  artifacts_bucket   = var.artifacts_bucket_name
  apt_bucket         = var.apt_bucket_name
  yum_bucket         = var.yum_bucket_name
  tags               = var.tags
}

# ─────────────────────────────────────────────────────────────────────────────
# One CodePipeline per PG major version
# ─────────────────────────────────────────────────────────────────────────────

module "pg_pipeline" {
  for_each = toset(var.pg_versions)
  source   = "./modules/pg-pipeline"

  pg_major              = each.value
  aws_region            = var.aws_region
  aws_account_id        = var.aws_account_id
  artifacts_bucket      = var.artifacts_bucket_name
  github_connection_arn = var.github_connection_arn
  packaging_repo        = var.packaging_repo
  # Extract just the repo name (after the "/") for EventBridge repositoryName filter
  packaging_repo_name   = split("/", var.packaging_repo)[1]
  platform_repo         = var.platform_repo
  codepipeline_role_arn = aws_iam_role.codepipeline.arn
  eventbridge_role_arn  = aws_iam_role.eventbridge.arn

  codebuild_parse_tag_project   = aws_codebuild_project.parse_tag.name
  codebuild_ubuntu_amd64_project = aws_codebuild_project.build_ubuntu_amd64.name
  codebuild_ubuntu_arm64_project = aws_codebuild_project.build_ubuntu_arm64.name
  codebuild_rpm_amd64_project    = aws_codebuild_project.build_rpm_amd64.name
  codebuild_rpm_arm64_project    = aws_codebuild_project.build_rpm_arm64.name
  codebuild_test_project         = aws_codebuild_project.test_install.name
  codebuild_repo_updater_project = module.repo_updater.project_name

  tags = var.tags
}
