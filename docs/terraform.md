# Terraform — Pipeline Infrastructure

All AWS resources for the mydbops PostgreSQL packaging pipeline are managed by
Terraform. Run `terraform apply` once to create everything; subsequent runs only
update what has changed.

---

## What Terraform manages

| Resource | Count |
|----------|-------|
| S3 buckets (artifacts, apt-repo, yum-repo) | 3 |
| ECR repository (`mydbops/pg-build`) | 1 |
| IAM roles (CodePipeline, CodeBuild, EventBridge) | 3 |
| SSM parameters (6 static + 6 dynamic placeholders) | 12 |
| Secrets Manager secrets (GPG key, optionally Pulp) | 1–2 |
| CodeBuild projects (parse-tag, 4 build, test, repo-updater) | 7 |
| CodePipeline V2 (one per PG major) | 4 (pg14–pg17) |
| EventBridge rules (one per PG major) | 4 |

Docker build images in ECR are **not** managed by Terraform — use
`scripts/manage-build-images.sh` (see `docs/build-images.md`).

---

## Directory layout

```
terraform/
├── main.tf                        ← root: S3, IAM, shared CodeBuild, module calls
├── variables.tf                   ← all input variables
├── outputs.tf                     ← useful ARNs + names
├── terraform.tfvars.example       ← template — copy and fill
└── modules/
    ├── pg-pipeline/
    │   ├── main.tf                ← CodePipeline V2 + EventBridge rule
    │   ├── variables.tf
    │   └── outputs.tf
    └── repo-updater/
        └── main.tf                ← repo-updater CodeBuild project
```

---

## Prerequisites

1. **Terraform ≥ 1.6** installed
2. **AWS credentials** with admin or infra-provisioner permissions
3. **CodeStar GitHub connection** created and OAuth completed (see step 1 below)

---

## First-time setup

### Step 1 — Create GitHub connection

```bash
aws codestar-connections create-connection \
  --provider-type GitHub \
  --connection-name Mydbopsllp \
  --region ap-south-1

# Get the connection ARN
aws codestar-connections list-connections \
  --query 'Connections[?ConnectionName==`Mydbopsllp`].ConnectionArn' \
  --output text
```

**Important:** Go to **AWS Console → Developer Tools → Connections** and click
**Update pending connection** to complete the OAuth handshake. The connection
must be in `AVAILABLE` state before `terraform apply`.

---

### Step 2 — Create GPG signing key

```bash
gpg --full-generate-key
# Choose: RSA 4096, no expiry (or set your org policy), set name/email

# Get the key ID
gpg --list-secret-keys --keyid-format LONG
# Example output: sec rsa4096/ABCDEF1234567890 ...
# Key ID is: ABCDEF1234567890

# Export as base64 (for terraform.tfvars or env var)
gpg --export-secret-keys --armor ABCDEF1234567890 | base64 -w0 > /tmp/gpg_b64.txt
```

---

### Step 3 — Configure variables

```bash
cd mydbops-pg-platform/terraform
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars`:

```hcl
aws_region     = "ap-south-1"
aws_account_id = "123456789012"

github_connection_arn = "arn:aws:codestar-connections:ap-south-1:123456789012:connection/..."

packaging_repo = "mydbops/mydbops-pg-packaging"
platform_repo  = "mydbops/mydbops-pg-platform"

artifacts_bucket_name = "mydbops-cicd-artifacts"
apt_bucket_name       = "mydbops-apt-repo"
yum_bucket_name       = "mydbops-yum-repo"

gpg_key_id = "ABCDEF1234567890"

pg_versions = ["14", "15", "16", "17"]
```

Set the GPG key via environment variable (avoids it appearing in tfvars):

```bash
export TF_VAR_gpg_private_key_b64="$(cat /tmp/gpg_b64.txt)"
```

---

### Step 4 — Apply

```bash
cd mydbops-pg-platform/terraform

terraform init
terraform plan    # review what will be created
terraform apply
```

Expected output (first run, ~2-3 min):
```
Plan: 47 to add, 0 to change, 0 to destroy.
Apply complete! Resources: 47 added, 0 changed, 0 destroyed.

Outputs:
  artifacts_bucket     = "mydbops-cicd-artifacts"
  ecr_repository_url   = "123456789012.dkr.ecr.ap-south-1.amazonaws.com/mydbops/pg-build"
  pipeline_arns        = {
    "14" = "arn:aws:codepipeline:ap-south-1:123456789012:mydbops-pkg-pg14"
    ...
  }
```

---

### Step 5 — Upload GPG key to Secrets Manager

Terraform creates the secret with a placeholder. Upload the real key:

```bash
aws secretsmanager put-secret-value \
  --secret-id mydbops/cicd/gpg-signing-key \
  --secret-string "$(cat /tmp/gpg_b64.txt)"

rm /tmp/gpg_b64.txt   # clean up
```

---

### Step 6 — Build and push Docker images

Terraform creates the ECR repo but not the images. Build them:

```bash
export ECR_ACCOUNT_ID=123456789012
export ECR_REGION=ap-south-1

cd mydbops-pg-platform
./scripts/manage-build-images.sh build
./scripts/manage-build-images.sh push
```

See `docs/build-images.md` for details and the list of 12 images.

---

### Step 7 — Smoke test

```bash
# Trigger with an RC tag (skips approval gate)
cd ../mydbops-pg-packaging
git checkout pg14
git tag pg14/postgresql-14-14.21-1-rc1
git push origin pg14/postgresql-14-14.21-1-rc1

# Watch in Console: CodePipeline → mydbops-pkg-pg14
```

---

## Day-to-day operations

### Add a new PG version (e.g. pg18)

1. Add `"18"` to `pg_versions` in `terraform.tfvars`
2. `terraform apply` — creates one new pipeline + one EventBridge rule
3. Create the packaging branch: `./scripts/new-pg-version.sh --new-major 18 ...`

### Remove a PG version (EOL)

1. Run `./scripts/eol.sh --pg-major 14 --confirm`
2. Remove `"14"` from `pg_versions` in `terraform.tfvars`
3. `terraform apply` — destroys the pg14 pipeline and EventBridge rule

### Update a static SSM value

Change the variable in `terraform.tfvars` and `terraform apply`. Example:

```hcl
# Change artifact bucket
artifacts_bucket_name = "mydbops-cicd-artifacts-v2"
```

### Rotate GPG key

The GPG key is in Secrets Manager — rotate via Console or CLI without touching Terraform:

```bash
gpg --export-secret-keys --armor NEW_KEY_ID | base64 -w0 | \
  xargs -I{} aws secretsmanager put-secret-value \
    --secret-id mydbops/cicd/gpg-signing-key \
    --secret-string {}

aws ssm put-parameter --name /mydbops/cicd/gpg/key_id \
  --value "NEW_KEY_ID" --type String --overwrite
```

### Temporarily disable a pipeline

Set the EventBridge rule to DISABLED without destroying the pipeline:

```bash
aws events disable-rule --name mydbops-trigger-pg14
# Re-enable:
aws events enable-rule --name mydbops-trigger-pg14
```

Or set `pipeline_enabled: false` in `config/pg-versions.yml` and remove the
version from `pg_versions` in `terraform.tfvars`.

---

## Remote state (recommended for teams)

Uncomment the `backend "s3"` block in `terraform/main.tf` and create the bucket
and DynamoDB table first:

```bash
aws s3 mb s3://mydbops-terraform-state --region ap-south-1

aws dynamodb create-table \
  --table-name mydbops-terraform-lock \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST \
  --region ap-south-1

terraform init   # migrates local state to S3
```

---

## What Terraform does NOT manage

| Resource | How to manage |
|----------|--------------|
| Docker build images in ECR | `scripts/manage-build-images.sh` |
| CloudFront distribution | Create manually or in separate Terraform workspace; set `cloudfront_distribution_id` variable |
| GitHub CodeStar Connection OAuth | AWS Console (one-time OAuth handshake) |
| GPG key content in Secrets Manager | `aws secretsmanager put-secret-value` |
| Pulp server | External — configure `pulp_url` + `pulp_password` variables |
| Package definitions (METADATA.yml, build.yml, spec) | `mydbops-pg-packaging` repo |

---

## Troubleshooting

| Problem | Fix |
|---------|-----|
| `terraform apply` fails — connection not found | Check `github_connection_arn` is correct and connection is `AVAILABLE` |
| `Error: S3 bucket already exists` | Bucket names must be globally unique; change `*_bucket_name` variables |
| Pipeline created but EventBridge never fires | Verify CodeStar connection is `AVAILABLE`; check EventBridge rule state |
| `Error: InvalidParameterException` on SSM | Parameter already exists with different type; import it: `terraform import aws_ssm_parameter.s3_bucket /mydbops/cicd/build/S3_BUCKET` |
| Build fails: ECR image not found | Docker images not pushed yet; run `manage-build-images.sh push` |
