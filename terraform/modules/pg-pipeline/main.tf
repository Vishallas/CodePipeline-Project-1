# ─────────────────────────────────────────────────────────────────────────────
# pg-pipeline module — one CodePipeline V2 + one EventBridge rule per PG major
#
# Instantiated once per entry in var.pg_versions in the root module.
# All CodeBuild projects are shared — passed in as variables.
# ─────────────────────────────────────────────────────────────────────────────

locals {
  pipeline_name = "mydbops-pkg-pg${var.pg_major}"
  branch_name   = "pg${var.pg_major}"
  eb_rule_name  = "mydbops-trigger-pg${var.pg_major}"

  # Dynamic build vars injected from ParseTag pipeline variables.
  # Using #{ParseTag.*} keeps each pipeline execution isolated — no SSM race
  # condition when pg14 and pg16 pipelines run simultaneously.
  build_env_vars = jsonencode([
    { name = "PACKAGE_NAME",     value = "#{ParseTag.PACKAGE_NAME}",     type = "PLAINTEXT" },
    { name = "PACKAGE_VERSION",  value = "#{ParseTag.PACKAGE_VERSION}",  type = "PLAINTEXT" },
    { name = "PACKAGE_REVISION", value = "#{ParseTag.PACKAGE_REVISION}", type = "PLAINTEXT" },
    { name = "PG_MAJOR",         value = "#{ParseTag.PG_MAJOR}",         type = "PLAINTEXT" },
    { name = "IS_RC",            value = "#{ParseTag.IS_RC}",            type = "PLAINTEXT" },
  ])
}

# ── CodePipeline V2 ───────────────────────────────────────────────────────────

resource "aws_codepipeline" "this" {
  name          = local.pipeline_name
  role_arn      = var.codepipeline_role_arn
  pipeline_type = "V2"
  tags          = var.tags

  # Pipeline-level variable — injected by EventBridge at start
  variable {
    name          = "GIT_TAG"
    default_value = ""
    description   = "Git tag that triggered this run (e.g. pg${var.pg_major}/postgresql-${var.pg_major}-14.21-1)"
  }

  artifact_store {
    type     = "S3"
    location = var.artifacts_bucket
  }

  # ── Stage 1: Source ─────────────────────────────────────────────────────────
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
        OutputArtifactFormat = "CODE_ZIP"
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

  # ── Stage 2: ParseTag ────────────────────────────────────────────────────────
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
        # Pass the pipeline variable GIT_TAG into the CodeBuild environment
        EnvironmentVariables = jsonencode([
          {
            name  = "GIT_TAG"
            value = "#{variables.GIT_TAG}"
            type  = "PLAINTEXT"
          }
        ])
      }
    }
  }

  # ── Stage 3: Build (4 parallel jobs) ─────────────────────────────────────────
  # Dynamic vars (PACKAGE_NAME, PACKAGE_VERSION, PACKAGE_REVISION, PG_MAJOR, IS_RC)
  # are injected via #{ParseTag.*} pipeline variables — NOT read from SSM.
  # This makes concurrent pg14/pg16 pipelines safe: each execution has its own vars.
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
        ProjectName   = var.codebuild_ubuntu_amd64_project
        PrimarySource = "platform_source"
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
        ProjectName   = var.codebuild_ubuntu_arm64_project
        PrimarySource = "platform_source"
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
        ProjectName   = var.codebuild_rpm_amd64_project
        PrimarySource = "platform_source"
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
        ProjectName   = var.codebuild_rpm_arm64_project
        PrimarySource = "platform_source"
        EnvironmentVariables = local.build_env_vars
      }
    }
  }

  # ── Stage 4: Test ─────────────────────────────────────────────────────────────
  stage {
    name = "Test"

    action {
      name            = "InstallTest"
      category        = "Build"
      owner           = "AWS"
      provider        = "CodeBuild"
      version         = "1"
      input_artifacts = ["packages_source", "platform_source"]

      configuration = {
        ProjectName          = var.codebuild_test_project
        PrimarySource        = "platform_source"
        EnvironmentVariables = local.build_env_vars
      }
    }
  }

  # ── Stage 5: Update staging repo metadata ─────────────────────────────────────
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

  # ── Stage 6: Manual approval ──────────────────────────────────────────────────
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

  # ── Stage 7: Promote to production ────────────────────────────────────────────
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
        # Merge build vars with BUILD_ENV=production override
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

# ── EventBridge rule — trigger on git tag push ────────────────────────────────
#
# AWS renamed CodeStar Connections → CodeConnections. The EventBridge source
# name varies by connection age: include BOTH to handle either.
#
# The repositoryName filter uses only the repo name (no org prefix), which is
# what the CodeConnections webhook sends in detail.repositoryName.

resource "aws_cloudwatch_event_rule" "tag_trigger" {
  name        = local.eb_rule_name
  description = "Start ${local.pipeline_name} when a pg${var.pg_major}/* git tag is pushed"
  state       = "ENABLED"
  tags        = var.tags

  event_pattern = jsonencode({
    # Include both source names: old (codestar-connections) and new (codeconnections)
    source = ["aws.codeconnections", "aws.codestar-connections"]
    "detail-type" = ["Connection Webhook Event"]
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
  arn       = aws_codepipeline.this.arn   # reference resource directly for correct dependency
  role_arn  = var.eventbridge_role_arn
  target_id = "pg${var.pg_major}-pipeline"

  # InputTransformer: extract the tag name from the webhook event and inject it
  # as a V2 pipeline variable so ParseTag CodeBuild receives it as $GIT_TAG.
  input_transformer {
    input_paths = {
      tag = "$.detail.referenceName"
    }
    # <tag> is replaced with the value from input_paths (a quoted JSON string)
    input_template = "{\"variables\": [{\"name\": \"GIT_TAG\", \"value\": <tag>}]}"
  }
}
