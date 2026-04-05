variable "codebuild_role_arn" {
  type = string
}

variable "codebuild_image" {
  type = string
}

variable "artifacts_bucket" {
  type = string
}

variable "apt_bucket" {
  type = string
}

variable "yum_bucket" {
  type = string
}

variable "tags" {
  type    = map(string)
  default = {}
}

resource "aws_codebuild_project" "repo_updater" {
  name          = "pg-platform-repo-updater"
  description   = "Regenerates APT (reprepro) and YUM (createrepo_c) repo metadata and syncs to S3"
  service_role  = var.codebuild_role_arn
  build_timeout = 20

  artifacts {
    type = "CODEPIPELINE"
  }

  environment {
    type            = "LINUX_CONTAINER"
    compute_type    = "BUILD_GENERAL1_SMALL"
    image           = var.codebuild_image
    privileged_mode = false

    environment_variable {
      name  = "ARTIFACTS_BUCKET"
      value = var.artifacts_bucket
    }

    environment_variable {
      name  = "APT_BUCKET"
      value = var.apt_bucket
    }

    environment_variable {
      name  = "YUM_BUCKET"
      value = var.yum_bucket
    }
  }

  source {
    type      = "CODEPIPELINE"
    buildspec = "buildspec/buildspec-repo-updater.yml"
  }

  logs_config {
    cloudwatch_logs {
      group_name  = "/aws/codebuild/pg-platform-repo-updater"
      stream_name = ""
    }
  }

  tags = var.tags
}

output "project_name" {
  value = aws_codebuild_project.repo_updater.name
}

output "project_arn" {
  value = aws_codebuild_project.repo_updater.arn
}
