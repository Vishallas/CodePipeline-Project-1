# Pipeline Infrastructure Setup

> **Ops/infra team reference.** All AWS infrastructure is managed by Terraform.
> Run `terraform apply` to create everything. Manual CLI steps are only needed
> for resources Terraform intentionally does not manage (GitHub OAuth, Docker
> images, GPG key upload).
>
> Developer workflow is in [pipeline-quickstart.md](pipeline-quickstart.md).
> Terraform usage details are in [terraform.md](terraform.md).

---

## Architecture Overview

```
GitHub push of git tag
        │
        ▼
  EventBridge Rule  (one rule per PG major — created by Terraform)
        │  matches tag pattern: pg14/*, pg15/*, pg16/*, pg17/*
        ▼
  CodePipeline V2  (mydbops-pkg-pg{N} — created by Terraform)
        │
        ├─ Stage 1: Source        ← two repos, two artifacts
        ├─ Stage 2: ParseTag      ← CodeBuild: parses tag → validates → writes SSM → exports vars
        ├─ Stage 3: Build         ← 4 parallel CodeBuild jobs → S3 staging
        ├─ Stage 4: Test          ← install test in clean containers
        ├─ Stage 5: Staging Repo  ← reprepro + createrepo_c → S3 repo indexes
        ├─ Stage 6: Approve       ← manual gate
        └─ Stage 7: Promote       ← s3 cp staging/ → production/ + repo metadata
```

---

## Setup: What Terraform Creates vs What You Do Manually

| Step | Method |
|------|--------|
| S3 buckets (artifacts, apt-repo, yum-repo) | Terraform |
| ECR repository | Terraform |
| IAM roles (CodePipeline, CodeBuild, EventBridge) | Terraform |
| SSM parameters (static config + dynamic placeholders) | Terraform |
| Secrets Manager secrets (GPG key, Pulp) | Terraform creates secret; you upload key value |
| CodeBuild projects (7 total) | Terraform |
| CodePipelines (one per PG major) | Terraform |
| EventBridge rules (one per PG major) | Terraform |
| GitHub CodeStar connection OAuth | **Manual** (Console only — AWS requirement) |
| Docker build images pushed to ECR | **Manual** (`manage-build-images.sh`) |
| GPG key content in Secrets Manager | **Manual** (`aws secretsmanager put-secret-value`) |
| CloudFront distribution | **Manual** (or separate Terraform workspace) |

---

## Full Setup Procedure

### 1. Create GitHub Connection

```bash
aws codestar-connections create-connection \
  --provider-type GitHub \
  --connection-name Mydbopsllp \
  --region ap-south-1

# Get the ARN — needed in terraform.tfvars
aws codestar-connections list-connections \
  --query 'Connections[?ConnectionName==`Mydbopsllp`].ConnectionArn' \
  --output text
```

Then go to **AWS Console → Developer Tools → Connections** and click
**Update pending connection** to complete OAuth. The connection must be
`AVAILABLE` before `terraform apply`.

---

### 2. Create GPG Signing Key

```bash
gpg --full-generate-key
# Algorithm: RSA 4096, expiry: per org policy, set name/email/passphrase

# Get the key ID
gpg --list-secret-keys --keyid-format LONG
# sec rsa4096/25C0FD60E1032324 ...  ← Key ID = 25C0FD60E1032324

# Export base64-encoded private key
gpg --export-secret-keys --armor 25C0FD60E1032324 | base64 -w0 > /tmp/gpg_b64.txt
```

---

### 3. Run Terraform

```bash
cd mydbops-pg-platform/terraform

cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars — fill aws_account_id, github_connection_arn,
# gpg_key_id, and verify bucket names + region

# Set GPG key via env var (keep out of terraform.tfvars)
export TF_VAR_gpg_private_key_b64="$(cat /tmp/gpg_b64.txt)"

terraform init
terraform plan     # review: should show ~47 resources to add
terraform apply
```

This creates all AWS resources: S3, ECR, IAM, SSM params, Secrets Manager
secrets (with placeholder values), 7 CodeBuild projects, 4 pipelines, 4
EventBridge rules.

---

### 4. Upload GPG Key to Secrets Manager

Terraform creates the secret with a placeholder. Upload the real key:

```bash
aws secretsmanager put-secret-value \
  --secret-id mydbops/cicd/gpg-signing-key \
  --secret-string "$(cat /tmp/gpg_b64.txt)"

rm /tmp/gpg_b64.txt
```

---

### 5. Build and Push Docker Images to ECR

Terraform creates the ECR repository but not the images. Build all 12:

```bash
export ECR_ACCOUNT_ID=123456789012
export ECR_REGION=ap-south-1

cd mydbops-pg-platform
./scripts/manage-build-images.sh build
./scripts/manage-build-images.sh push
```

See `docs/build-images.md` for the full list of images and rebuild guidance.

---

### 6. (Optional) Set CloudFront Distribution

If you have a CloudFront distribution fronting the APT/YUM S3 buckets:

```bash
# Update the SSM param directly (or set cloudfront_distribution_id in tfvars + terraform apply)
aws ssm put-parameter \
  --name /mydbops/cicd/cloudfront/distribution_id \
  --value "EXXXXXXXXX" \
  --type String --overwrite
```

---

### 7. Smoke Test

```bash
cd ../mydbops-pg-packaging
git checkout pg14
git tag pg14/postgresql-14-14.21-1-rc1
git push origin pg14/postgresql-14-14.21-1-rc1
```

Watch: **AWS Console → CodePipeline → mydbops-pkg-pg14** — stages should turn green.
RC tags skip the Approve stage (IS_RC=true from ParseTag).

---

## SSM Parameters Reference

### Static (created by Terraform, rarely change)

| Parameter | Value |
|-----------|-------|
| `/mydbops/cicd/build/S3_BUCKET` | Artifacts bucket name |
| `/mydbops/cicd/build/BUILD_ENV` | `staging` |
| `/mydbops/cicd/ecr/account_id` | AWS account ID |
| `/mydbops/cicd/ecr/region` | AWS region |
| `/mydbops/cicd/gpg/key_id` | GPG key fingerprint |
| `/mydbops/cicd/cloudfront/distribution_id` | CloudFront dist ID |

### Dynamic (written by ParseTag CodeBuild on every pipeline run)

| Parameter | Written by |
|-----------|-----------|
| `/mydbops/cicd/build/PACKAGE_NAME` | `buildspec-parse-tag.yml` |
| `/mydbops/cicd/build/PACKAGE_VERSION` | `buildspec-parse-tag.yml` |
| `/mydbops/cicd/build/PACKAGE_REVISION` | `buildspec-parse-tag.yml` |
| `/mydbops/cicd/build/PG_MAJOR` | `buildspec-parse-tag.yml` |
| `/mydbops/cicd/build/GIT_TAG` | `buildspec-parse-tag.yml` |
| `/mydbops/cicd/build/IS_RC` | `buildspec-parse-tag.yml` |

Dynamic params are overwritten (`--overwrite`) atomically on every run.
Terraform creates them with placeholder values and ignores subsequent changes.

### Secrets Manager

| Secret | Content |
|--------|---------|
| `mydbops/cicd/gpg-signing-key` | Base64-encoded GPG private key |
| `mydbops/cicd/pulp-password` | Pulp API password (only if `pulp_url` is set) |

---

## ParseTag Stage — How It Works

Stage 2 is a CodeBuild project (`mydbops-parse-tag`), **no Lambda required**.

Flow:
1. EventBridge injects `GIT_TAG` as a V2 pipeline variable when starting the pipeline
2. CodePipeline passes it to ParseTag via `EnvironmentVariables` in the stage config
3. `buildspec-parse-tag.yml` receives `$GIT_TAG`, parses it with Python regex
4. Validates parsed version against `METADATA.yml` in `packages_source`
5. Writes 6 values to SSM `/mydbops/cicd/build/*` (overwrite)
6. Exports same values as CodeBuild pipeline variables (namespace: `ParseTag`)
7. Downstream stages reference them as `#{ParseTag.PACKAGE_NAME}` etc.

**Variable flow:**
```
EventBridge injects:  variables[GIT_TAG] = "pg14/postgresql-14-14.21-1"
      ↓
CodePipeline V2 makes #{variables.GIT_TAG} available
      ↓
ParseTag stage env: GIT_TAG=#{variables.GIT_TAG}
      ↓
buildspec-parse-tag.yml → parses → writes SSM → exports #{ParseTag.*}
      ↓
Build stages read PACKAGE_NAME etc. from SSM via parameter-store block
```

---

## How to Trigger the Pipeline

### Automatic — git tag push (primary method)

```bash
cd mydbops-pg-packaging
git checkout pg14

git tag pg14/postgresql-14-14.21-1
git push origin pg14/postgresql-14-14.21-1
```

Tag format:
```
pg{major}/{package-name}-{version}-{revision}[-rcN]

pg14/postgresql-14-14.21-1          ← full pipeline (build → approve → promote)
pg14/postgresql-14-pgvector-0.7.4-1 ← extension build
pg14/postgresql-14-14.22-1-rc1      ← RC: staging only, skips Approve stage
tools/pgbouncer-1.22.0-1            ← tools pipeline
```

EventBridge detects the tag and starts `mydbops-pkg-pg14` within ~1 minute.

### Manual — AWS CLI

```bash
# Must pass GIT_TAG when triggering manually
aws codepipeline start-pipeline-execution \
  --name mydbops-pkg-pg14 \
  --variables name=GIT_TAG,value=pg14/postgresql-14-14.21-1
```

### Manual — AWS Console

**CodePipeline → mydbops-pkg-pg14 → Release change.**
Use for: re-running a failed build, testing infra changes.

### RC Builds (staging only)

```bash
git tag pg14/postgresql-14-14.22-1-rc1
git push origin pg14/postgresql-14-14.22-1-rc1
```

ParseTag sets `IS_RC=true` → Approve stage is skipped →
package lands in `s3://.../staging/` only, never promoted to production.

---

## Full Pipeline Flow

```
[Tag pushed: pg14/postgresql-14-14.21-1]
    │
    ▼
EventBridge rule mydbops-trigger-pg14 fires (~1 min after push)
    │  Injects: variables[GIT_TAG] = "pg14/postgresql-14-14.21-1"
    ▼
Stage 1: Source
    ├─ packages_source: checkout mydbops-pg-packaging @ pg14
    └─ platform_source: checkout mydbops-pg-platform @ main

Stage 2: ParseTag  (~1-2 min)
    ├─ Receives GIT_TAG from pipeline variable
    ├─ Parses: PACKAGE_NAME=postgresql-14, VERSION=14.21, REVISION=1, IS_RC=false
    ├─ Validates version matches packages/postgresql-14/METADATA.yml
    ├─ Writes 6 SSM params under /mydbops/cicd/build/
    └─ Exports #{ParseTag.*} pipeline variables

Stage 3: Build  (4 jobs in parallel, ~10-30 min)
    ├─ ubuntu-amd64 → build-package.sh --os ubuntu → s3 staging/ubuntu-{20,22,24}-amd64/
    ├─ ubuntu-arm64 → build-package.sh --os ubuntu → s3 staging/ubuntu-{22,24}-arm64/
    ├─ rpm-amd64   → build-package.sh --os epel+fedora → s3 staging/epel-*/f4*-*/
    └─ rpm-arm64   → build-package.sh --os epel → s3 staging/epel-*-aarch64/

Stage 4: Test  (~5 min)
    test_install.sh: pulls each package from S3 staging, installs in clean container
    → fails pipeline if any target fails to install

Stage 5: UpdateStagingRepo  (~3 min)
    reprepro → APT staging index → s3://mydbops-apt-repo/staging/
    createrepo_c → YUM staging index → s3://mydbops-yum-repo/staging/
    CloudFront invalidation

Stage 6: Approve  (MANUAL)
    Approval message: "Approve promotion of postgresql-14 14.21-1 to production?"
    → Operator reviews, clicks Approve in Console

Stage 7: PromoteToProduction  (~5 min)
    s3 cp staging/packages/postgresql-14/14.21-1/ → production/packages/...
    (COPY — same binaries, not a rebuild)
    reprepro + createrepo_c → production APT/YUM indexes
    CloudFront invalidation
```

---

## Verifying the Setup

```bash
# 1. Confirm Terraform outputs look correct
cd mydbops-pg-platform/terraform
terraform output

# 2. Confirm SSM params
aws ssm get-parameters \
  --names /mydbops/cicd/build/S3_BUCKET \
          /mydbops/cicd/ecr/account_id \
          /mydbops/cicd/ecr/region \
  --query 'Parameters[*].[Name,Value]' --output table

# 3. Confirm ECR images exist
aws ecr list-images \
  --repository-name mydbops/pg-build \
  --query 'imageIds[*].imageTag' --output table

# 4. Confirm CodeBuild projects
aws codebuild batch-get-projects \
  --names mydbops-parse-tag mydbops-build-ubuntu-amd64 mydbops-repo-updater \
  --query 'projects[*].[name,created]' --output table

# 5. Confirm pipelines
aws codepipeline list-pipelines \
  --query 'pipelines[?starts_with(name,`mydbops-pkg`)].name' --output table

# 6. Confirm EventBridge rules
aws events list-rules --name-prefix mydbops-trigger \
  --query 'Rules[*].[Name,State]' --output table
```

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| Tag push does nothing | EventBridge rule not active or CodeStar connection not `AVAILABLE` | Check rule state; complete OAuth in Console |
| Stage 2 fails — tag format invalid | Tag doesn't match `pg{N}/{name}-{version}-{revision}` | Fix tag format; retag |
| Stage 2 fails — version mismatch | Tag version differs from `METADATA.yml` | Update METADATA.yml version and retag |
| Stage 2 fails — GIT_TAG empty | Pipeline started manually without `--variables` | Add `--variables name=GIT_TAG,value=...` to CLI trigger |
| Stage 2 fails — SSM write denied | CodeBuild role missing `ssm:PutParameter` on `/mydbops/cicd/build/*` | `terraform apply` re-syncs IAM policy |
| Stage 3 fails — image not found | ECR image not built for that target | Run `manage-build-images.sh build --target <tag> && push` |
| Stage 3 fails — Docker error | `privileged_mode = false` on CodeBuild project | `terraform apply` — projects are defined with `privileged_mode = true` |
| Stage 3 fails — tarball 404 | Wrong `source_url` in `METADATA.yml` | Fix URL, bump revision, retag |
| Stage 4 fails — version mismatch | Installed package version differs from expected | Check `PACKAGE_VERSION` SSM param vs actual binary output |
| Approve stage skipped | RC tag (`-rc1` suffix) — intended | Normal behaviour; RC builds are staging-only |
| Production S3 empty after Stage 7 | `BUILD_ENV` env var wrong in Stage 7 config | Terraform sets `BUILD_ENV=production` on Stage 7; `terraform apply` to fix |
| `terraform apply` fails — bucket exists | Bucket name already taken globally | Change `*_bucket_name` variables |
| `terraform apply` fails — SSM conflict | Param exists with different type | Import: `terraform import aws_ssm_parameter.s3_bucket /mydbops/cicd/build/S3_BUCKET` |

---

## Setup Checklist

```
Terraform (run once):
  [ ] terraform.tfvars filled: aws_account_id, github_connection_arn, gpg_key_id
  [ ] TF_VAR_gpg_private_key_b64 set
  [ ] terraform init && terraform apply — all resources created

Manual (one-time):
  [ ] GitHub connection OAuth completed in Console (status: AVAILABLE)
  [ ] GPG key value uploaded to Secrets Manager (mydbops/cicd/gpg-signing-key)
  [ ] All 12 Docker build images built and pushed to ECR
  [ ] CloudFront distribution ID set in SSM (if using CDN)

Verify:
  [ ] terraform output shows all 4 pipeline ARNs
  [ ] SSM params readable (see verification commands above)
  [ ] ECR has 12 images
  [ ] Smoke test: push an RC tag → watch pipeline complete
```
