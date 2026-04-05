terraform {
  required_version = ">= 1.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # backend "s3" {
  #   bucket         = "pg-platform-terraform-state"
  #   key            = "pg-packaging/terraform.tfstate"
  #   region         = "ap-south-1"
  #   dynamodb_table = "pg-platform-terraform-lock"
  #   encrypt        = true
  # }
}

provider "aws" {
  region = var.aws_region
}

locals {
  codepipeline_role_name = "pg-platform-codepipeline-role"
  codebuild_role_name    = "pg-platform-codebuild-role"
  eventbridge_role_name  = "pg-platform-eventbridge-role"
}

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
      description  = "Keep last 30 images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 30
      }
      action = { type = "expire" }
    }]
  })
}

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
  name = "pg-platform-codepipeline-policy"
  role = aws_iam_role.codepipeline.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "CodeBuildAccess"
        Effect   = "Allow"
        Action   = ["codebuild:StartBuild", "codebuild:BatchGetBuilds"]
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
        Sid      = "ReadSSM"
        Effect   = "Allow"
        Action   = ["ssm:GetParameter", "ssm:GetParameters"]
        Resource = "arn:aws:ssm:${var.aws_region}:${var.aws_account_id}:parameter/pg-platform/cicd/*"
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
  name = "pg-platform-codebuild-policy"
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
        Sid    = "GitHubCloneRef"
        Effect = "Allow"
        Action = [
          "codeconnections:UseConnection",
          "codestar-connections:UseConnection"
        ]
        Resource = var.github_connection_arn
      },
      {
        Sid      = "SSMRead"
        Effect   = "Allow"
        Action   = ["ssm:GetParameter", "ssm:GetParameters"]
        Resource = "arn:aws:ssm:${var.aws_region}:${var.aws_account_id}:parameter/pg-platform/cicd/*"
      },
      {
        Sid      = "SSMWrite"
        Effect   = "Allow"
        Action   = ["ssm:PutParameter"]
        Resource = "arn:aws:ssm:${var.aws_region}:${var.aws_account_id}:parameter/pg-platform/cicd/build/*"
      },
      {
        Sid      = "Secrets"
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = "arn:aws:secretsmanager:${var.aws_region}:${var.aws_account_id}:secret:pg-platform/cicd/*"
      },
      {
        Sid    = "Logs"
        Effect = "Allow"
        Action = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "arn:aws:logs:${var.aws_region}:${var.aws_account_id}:log-group:/aws/codebuild/pg-platform-*"
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
  name = "pg-platform-eventbridge-policy"
  role = aws_iam_role.eventbridge.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["codepipeline:StartPipelineExecution"]
      Resource = "arn:aws:codepipeline:${var.aws_region}:${var.aws_account_id}:pg-platform-pkg-pg*"
    }]
  })
}

resource "aws_ssm_parameter" "s3_bucket" {
  name  = "/pg-platform/cicd/build/S3_BUCKET"
  type  = "String"
  value = var.artifacts_bucket_name
  tags  = var.tags
}

resource "aws_ssm_parameter" "build_env" {
  name  = "/pg-platform/cicd/build/BUILD_ENV"
  type  = "String"
  value = var.build_env
  tags  = var.tags
}

resource "aws_ssm_parameter" "ecr_account_id" {
  name  = "/pg-platform/cicd/ecr/account_id"
  type  = "String"
  value = var.aws_account_id
  tags  = var.tags
}

resource "aws_ssm_parameter" "ecr_region" {
  name  = "/pg-platform/cicd/ecr/region"
  type  = "String"
  value = var.aws_region
  tags  = var.tags
}

resource "aws_ssm_parameter" "gpg_key_id" {
  name  = "/pg-platform/cicd/gpg/key_id"
  type  = "String"
  value = var.gpg_key_id
  tags  = var.tags
}

resource "aws_ssm_parameter" "cloudfront_distribution_id" {
  count = (
    var.cloudfront_distribution_id != null &&
    var.cloudfront_distribution_id != ""
  ) ? 1 : 0

  name      = "/pg-platform/cicd/cloudfront/distribution_id"
  type      = "String"
  value     = var.cloudfront_distribution_id
  overwrite = true
  tags      = var.tags
}

resource "aws_ssm_parameter" "package_name" {
  name      = "/pg-platform/cicd/build/PACKAGE_NAME"
  type      = "String"
  value     = "placeholder"
  overwrite = true
  tags      = var.tags

  lifecycle { ignore_changes = [value] }
}

resource "aws_ssm_parameter" "package_version" {
  name      = "/pg-platform/cicd/build/PACKAGE_VERSION"
  type      = "String"
  value     = "placeholder"
  overwrite = true
  tags      = var.tags

  lifecycle { ignore_changes = [value] }
}

resource "aws_ssm_parameter" "package_revision" {
  name      = "/pg-platform/cicd/build/PACKAGE_REVISION"
  type      = "String"
  value     = "placeholder"
  overwrite = true
  tags      = var.tags

  lifecycle { ignore_changes = [value] }
}

resource "aws_ssm_parameter" "pg_major" {
  name      = "/pg-platform/cicd/build/PG_MAJOR"
  type      = "String"
  value     = "placeholder"
  overwrite = true
  tags      = var.tags

  lifecycle { ignore_changes = [value] }
}

resource "aws_ssm_parameter" "git_tag" {
  name      = "/pg-platform/cicd/build/GIT_TAG"
  type      = "String"
  value     = "placeholder"
  overwrite = true
  tags      = var.tags

  lifecycle { ignore_changes = [value] }
}

resource "aws_ssm_parameter" "is_rc" {
  name      = "/pg-platform/cicd/build/IS_RC"
  type      = "String"
  value     = "false"
  overwrite = true
  tags      = var.tags

  lifecycle { ignore_changes = [value] }
}

resource "aws_secretsmanager_secret" "gpg_signing_key" {
  name                    = "pg-platform/cicd/gpg-signing-key"
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
  name                    = "pg-platform/cicd/pulp-password"
  description             = "Pulp API password"
  recovery_window_in_days = 7
  tags                    = var.tags
}

resource "aws_secretsmanager_secret_version" "pulp_password" {
  count         = var.pulp_url != "" ? 1 : 0
  secret_id     = aws_secretsmanager_secret.pulp_password[0].id
  secret_string = var.pulp_password != "" ? var.pulp_password : "REPLACE_WITH_PULP_PASSWORD"

  lifecycle { ignore_changes = [secret_string] }
}

resource "aws_codebuild_project" "parse_tag" {
  name          = "pg-platform-parse-tag"
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
      group_name  = "/aws/codebuild/pg-platform-parse-tag"
      stream_name = ""
    }
  }

  tags = var.tags
}

resource "aws_codebuild_project" "build_ubuntu_amd64" {
  name          = "pg-platform-build-ubuntu-amd64"
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
      group_name  = "/aws/codebuild/pg-platform-build-ubuntu-amd64"
      stream_name = ""
    }
  }

  tags = var.tags
}

resource "aws_codebuild_project" "build_ubuntu_arm64" {
  name          = "pg-platform-build-ubuntu-arm64"
  description   = "Builds .deb packages for Ubuntu 22/24 on aarch64"
  service_role  = aws_iam_role.codebuild.arn
  build_timeout = 60

  artifacts { type = "CODEPIPELINE" }

  environment {
    type            = "ARM_CONTAINER"
    compute_type    = "BUILD_GENERAL1_LARGE"
    image           = "aws/codebuild/amazonlinux-aarch64-standard:3.0"
    privileged_mode = true
  }

  source {
    type      = "CODEPIPELINE"
    buildspec = "buildspec/buildspec-ubuntu-arm64.yml"
  }

  logs_config {
    cloudwatch_logs {
      group_name  = "/aws/codebuild/pg-platform-build-ubuntu-arm64"
      stream_name = ""
    }
  }

  tags = var.tags
}

resource "aws_codebuild_project" "build_rpm_amd64" {
  name          = "pg-platform-build-rpm-amd64"
  description   = "Builds .rpm packages for EPEL 8/9/10 + Fedora 42/43 on x86_64"
  service_role  = aws_iam_role.codebuild.arn
  build_timeout = 60

  artifacts { type = "CODEPIPELINE" }

  environment {
    type            = "LINUX_CONTAINER"
    compute_type    = var.codebuild_compute_type
    image           = "aws/codebuild/amazonlinux-x86_64-standard:5.0"
    privileged_mode = true
  }

  source {
    type      = "CODEPIPELINE"
    buildspec = "buildspec/buildspec-rpm-amd64.yml"
  }

  logs_config {
    cloudwatch_logs {
      group_name  = "/aws/codebuild/pg-platform-build-rpm-amd64"
      stream_name = ""
    }
  }

  tags = var.tags
}

resource "aws_codebuild_project" "build_rpm_arm64" {
  name          = "pg-platform-build-rpm-arm64"
  description   = "Builds .rpm packages for EPEL 8/9 on aarch64"
  service_role  = aws_iam_role.codebuild.arn
  build_timeout = 60

  artifacts { type = "CODEPIPELINE" }

  environment {
    type            = "ARM_CONTAINER"
    compute_type    = "BUILD_GENERAL1_LARGE"
    image           = "aws/codebuild/amazonlinux-aarch64-standard:3.0"
    privileged_mode = true
  }

  source {
    type      = "CODEPIPELINE"
    buildspec = "buildspec/buildspec-rpm-arm64.yml"
  }

  logs_config {
    cloudwatch_logs {
      group_name  = "/aws/codebuild/pg-platform-build-rpm-arm64"
      stream_name = ""
    }
  }

  tags = var.tags
}

resource "aws_codebuild_project" "test_install" {
  name          = "pg-platform-test-install"
  description   = "Install-tests x86_64 packages from S3 staging in clean containers"
  service_role  = aws_iam_role.codebuild.arn
  build_timeout = 30

  artifacts { type = "CODEPIPELINE" }

  environment {
    type            = "LINUX_CONTAINER"
    compute_type    = "BUILD_GENERAL1_MEDIUM"
    image           = "aws/codebuild/amazonlinux2-x86_64-standard:5.0"
    privileged_mode = true
  }

  source {
    type      = "CODEPIPELINE"
    buildspec = "buildspec/buildspec-test.yml"
  }

  logs_config {
    cloudwatch_logs {
      group_name  = "/aws/codebuild/pg-platform-test-install"
      stream_name = ""
    }
  }

  tags = var.tags
}

resource "aws_codebuild_project" "test_install_arm64" {
  name          = "pg-platform-test-install-arm64"
  description   = "Install-tests aarch64 packages from S3 staging in clean containers"
  service_role  = aws_iam_role.codebuild.arn
  build_timeout = 30

  artifacts { type = "CODEPIPELINE" }

  environment {
    type            = "ARM_CONTAINER"
    compute_type    = "BUILD_GENERAL1_LARGE"
    image           = "aws/codebuild/amazonlinux-aarch64-standard:3.0"
    privileged_mode = true
  }

  source {
    type      = "CODEPIPELINE"
    buildspec = "buildspec/buildspec-test.yml"
  }

  logs_config {
    cloudwatch_logs {
      group_name  = "/aws/codebuild/pg-platform-test-install-arm64"
      stream_name = ""
    }
  }

  tags = var.tags
}

module "repo_updater" {
  source = "./modules/repo-updater"

  codebuild_role_arn = aws_iam_role.codebuild.arn
  codebuild_image    = var.codebuild_image
  artifacts_bucket   = var.artifacts_bucket_name
  apt_bucket         = var.apt_bucket_name
  yum_bucket         = var.yum_bucket_name
  tags               = var.tags
}

module "pg_pipeline" {
  for_each = toset(var.pg_versions)
  source   = "./modules/pg-pipeline"

  pg_major              = each.value
  aws_region            = var.aws_region
  aws_account_id        = var.aws_account_id
  artifacts_bucket      = var.artifacts_bucket_name
  github_connection_arn = var.github_connection_arn
  packaging_repo        = var.packaging_repo
  packaging_repo_name   = split("/", var.packaging_repo)[1]
  platform_repo         = var.platform_repo
  codepipeline_role_arn = aws_iam_role.codepipeline.arn
  eventbridge_role_arn  = aws_iam_role.eventbridge.arn

  codebuild_parse_tag_project    = aws_codebuild_project.parse_tag.name
  codebuild_ubuntu_amd64_project = aws_codebuild_project.build_ubuntu_amd64.name
  codebuild_ubuntu_arm64_project = aws_codebuild_project.build_ubuntu_arm64.name
  codebuild_rpm_amd64_project    = aws_codebuild_project.build_rpm_amd64.name
  codebuild_rpm_arm64_project    = aws_codebuild_project.build_rpm_arm64.name
  codebuild_test_project         = aws_codebuild_project.test_install.name
  codebuild_test_arm64_project   = aws_codebuild_project.test_install_arm64.name
  codebuild_repo_updater_project = module.repo_updater.project_name

  tags = var.tags
}
