locals {
  pipeline_name = "pg-platform-pkg-pg${var.pg_major}"
  branch_name   = "pg${var.pg_major}"
  eb_rule_name  = "pg-platform-trigger-pg${var.pg_major}"

  build_env_vars = jsonencode([
    { name = "PACKAGE_NAME",     value = "#{ParseTag.PACKAGE_NAME}",     type = "PLAINTEXT" },
    { name = "PACKAGE_VERSION",  value = "#{ParseTag.PACKAGE_VERSION}",  type = "PLAINTEXT" },
    { name = "PACKAGE_REVISION", value = "#{ParseTag.PACKAGE_REVISION}", type = "PLAINTEXT" },
    { name = "PG_MAJOR",         value = "#{ParseTag.PG_MAJOR}",         type = "PLAINTEXT" },
    { name = "IS_RC",            value = "#{ParseTag.IS_RC}",            type = "PLAINTEXT" },
    { name = "BUILD_ENV",        value = "staging",                      type = "PLAINTEXT" },
    { name = "GIT_TAG",          value = "#{ParseTag.GIT_TAG}",          type = "PLAINTEXT" },
  ])
}

resource "aws_codepipeline" "this" {
  name          = local.pipeline_name
  role_arn      = var.codepipeline_role_arn
  pipeline_type = "V2"
  tags          = var.tags

  artifact_store {
    type     = "S3"
    location = var.artifacts_bucket
  }

  variable {
    name          = "GIT_TAG"
    default_value = "auto"
  }

  trigger {
    provider_type = "CodeStarSourceConnection"
    git_configuration {
      source_action_name = "packages_source"
      push {
        tags {
          includes = ["pg${var.pg_major}/*"]
        }
      }
    }
  }

  stage {
    name = "Source"

    action {
      name             = "packages_source"
      category         = "Source"
      owner            = "AWS"
      provider         = "CodeStarSourceConnection"
      version          = "1"
      output_artifacts = ["packages_source"]

      configuration = {
        ConnectionArn        = var.github_connection_arn
        FullRepositoryId     = var.packaging_repo
        BranchName           = local.branch_name
        OutputArtifactFormat = "CODEBUILD_CLONE_REF"
        DetectChanges        = "false"
      }
    }

    action {
      name             = "platform_source"
      category         = "Source"
      owner            = "AWS"
      provider         = "CodeStarSourceConnection"
      version          = "1"
      output_artifacts = ["platform_source"]

      configuration = {
        ConnectionArn        = var.github_connection_arn
        FullRepositoryId     = var.platform_repo
        BranchName           = "main"
        OutputArtifactFormat = "CODE_ZIP"
        DetectChanges        = "false"
      }
    }
  }

  stage {
    name = "ParseTag"

    action {
      name             = "ParseTag"
      category         = "Build"
      owner            = "AWS"
      provider         = "CodeBuild"
      version          = "1"
      input_artifacts  = ["packages_source", "platform_source"]
      namespace        = "ParseTag"

      configuration = {
        ProjectName   = var.codebuild_parse_tag_project
        PrimarySource = "platform_source"
        EnvironmentVariables = jsonencode([
          {
            name  = "BRANCH_REF"
            value = "#{variables.GIT_TAG}"
            type  = "PLAINTEXT"
          },
          {
            name  = "PG_MAJOR_HINT"
            value = tostring(var.pg_major)
            type  = "PLAINTEXT"
          }
        ])
      }
    }
  }

  stage {
    name = "Build"

    action {
      name             = "ubuntu-amd64"
      category         = "Build"
      owner            = "AWS"
      provider         = "CodeBuild"
      version          = "1"
      run_order        = 1
      input_artifacts  = ["packages_source", "platform_source"]

      configuration = {
        ProjectName          = var.codebuild_ubuntu_amd64_project
        PrimarySource        = "platform_source"
        EnvironmentVariables = local.build_env_vars
      }
    }

    action {
      name             = "ubuntu-arm64"
      category         = "Build"
      owner            = "AWS"
      provider         = "CodeBuild"
      version          = "1"
      run_order        = 1
      input_artifacts  = ["packages_source", "platform_source"]

      configuration = {
        ProjectName          = var.codebuild_ubuntu_arm64_project
        PrimarySource        = "platform_source"
        EnvironmentVariables = local.build_env_vars
      }
    }

    action {
      name             = "rpm-amd64"
      category         = "Build"
      owner            = "AWS"
      provider         = "CodeBuild"
      version          = "1"
      run_order        = 1
      input_artifacts  = ["packages_source", "platform_source"]

      configuration = {
        ProjectName          = var.codebuild_rpm_amd64_project
        PrimarySource        = "platform_source"
        EnvironmentVariables = local.build_env_vars
      }
    }

    action {
      name             = "rpm-arm64"
      category         = "Build"
      owner            = "AWS"
      provider         = "CodeBuild"
      version          = "1"
      run_order        = 1
      input_artifacts  = ["packages_source", "platform_source"]

      configuration = {
        ProjectName          = var.codebuild_rpm_arm64_project
        PrimarySource        = "platform_source"
        EnvironmentVariables = local.build_env_vars
      }
    }
  }

  stage {
    name = "Test"

    action {
      name            = "InstallTest-amd64"
      category        = "Build"
      owner           = "AWS"
      provider        = "CodeBuild"
      version         = "1"
      run_order       = 1
      input_artifacts = ["packages_source", "platform_source"]

      configuration = {
        ProjectName          = var.codebuild_test_project
        PrimarySource        = "platform_source"
        EnvironmentVariables = local.build_env_vars
      }
    }

    action {
      name            = "InstallTest-arm64"
      category        = "Build"
      owner           = "AWS"
      provider        = "CodeBuild"
      version         = "1"
      run_order       = 1
      input_artifacts = ["packages_source", "platform_source"]

      configuration = {
        ProjectName          = var.codebuild_test_arm64_project
        PrimarySource        = "platform_source"
        EnvironmentVariables = local.build_env_vars
      }
    }
  }

  stage {
    name = "UpdateStagingRepo"

    action {
      name            = "RepoMetadata"
      category        = "Build"
      owner           = "AWS"
      provider        = "CodeBuild"
      version         = "1"
      input_artifacts = ["packages_source", "platform_source"]

      configuration = {
        ProjectName          = var.codebuild_repo_updater_project
        PrimarySource        = "platform_source"
        EnvironmentVariables = local.build_env_vars
      }
    }
  }

  stage {
    name = "Approve"

    action {
      name     = "ManualApproval"
      category = "Approval"
      owner    = "AWS"
      provider = "Manual"
      version  = "1"

      configuration = {
        CustomData = "Approve promotion of #{ParseTag.PACKAGE_NAME} #{ParseTag.PACKAGE_VERSION}-#{ParseTag.PACKAGE_REVISION} to production?"
      }
    }
  }

  stage {
    name = "PromoteToProduction"

    action {
      name            = "Promote"
      category        = "Build"
      owner           = "AWS"
      provider        = "CodeBuild"
      version         = "1"
      input_artifacts = ["packages_source", "platform_source"]

      configuration = {
        ProjectName   = var.codebuild_repo_updater_project
        PrimarySource = "platform_source"
        EnvironmentVariables = jsonencode([
          { name = "PACKAGE_NAME",     value = "#{ParseTag.PACKAGE_NAME}",     type = "PLAINTEXT" },
          { name = "PACKAGE_VERSION",  value = "#{ParseTag.PACKAGE_VERSION}",  type = "PLAINTEXT" },
          { name = "PACKAGE_REVISION", value = "#{ParseTag.PACKAGE_REVISION}", type = "PLAINTEXT" },
          { name = "PG_MAJOR",         value = "#{ParseTag.PG_MAJOR}",         type = "PLAINTEXT" },
          { name = "IS_RC",            value = "#{ParseTag.IS_RC}",            type = "PLAINTEXT" },
          { name = "BUILD_ENV",        value = "production",                    type = "PLAINTEXT" },
        ])
      }
    }
  }
}

resource "aws_cloudwatch_event_rule" "tag_trigger" {
  name        = local.eb_rule_name
  description = "Start ${local.pipeline_name} when a pg${var.pg_major}/* git tag is pushed"
  state       = "DISABLED"
  tags        = var.tags

  event_pattern = jsonencode({
    source = ["aws.codeconnections", "aws.codestar-connections"]
    "detail-type" = [
      "CodeConnections Source Webhook Event",
      "CodeStar Connections Source Webhook Event",
      "Connection Webhook Event"
    ]
    detail = {
      event          = ["referenceCreated"]
      referenceType  = ["tag"]
      referenceName  = [{ prefix = "pg${var.pg_major}/" }]
      repositoryName = [var.packaging_repo_name]
    }
  })
}

resource "aws_cloudwatch_event_target" "pipeline" {
  rule      = aws_cloudwatch_event_rule.tag_trigger.name
  arn       = aws_codepipeline.this.arn
  role_arn  = var.eventbridge_role_arn
  target_id = "pg${var.pg_major}-pipeline"

  input_transformer {
    input_paths = {
      tag = "$.detail.referenceName"
    }
    input_template = "{\"variables\": [{\"name\": \"GIT_TAG\", \"value\": <tag>}]}"
  }
}
