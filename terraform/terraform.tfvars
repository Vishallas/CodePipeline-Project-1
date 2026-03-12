# ─────────────────────────────────────────────────────────────────────────────
# terraform.tfvars.example — copy to terraform.tfvars and fill in real values
# Do NOT commit terraform.tfvars — it contains secrets
# ─────────────────────────────────────────────────────────────────────────────

aws_region     = "ap-south-1"
aws_account_id = "145687388766"

# Get this ARN after running:
#   aws codestar-connections create-connection --provider-type GitHub --connection-name Mydbopsllp
# Then complete OAuth in Console → Developer Tools → Connections
# github_connection_arn = "arn:aws:codeconnections:ap-south-1:145687388766:connection/f4c35638-d363-42d1-81b3-d6d252a9d49a"
github_connection_arn = "arn:aws:codeconnections:ap-south-1:145687388766:connection/bf0fa12e-f315-422d-b2eb-1732432932fc"
packaging_repo = "mydbopsllp/mydbops-pg-packaging"
platform_repo  = "mydbopsllp/mydbops-pg-platform"

# S3 bucket names — must be globally unique
artifacts_bucket_name = "mydbops-cicd-artifacts-1"
apt_bucket_name       = "mydbops-apt-repo-1"
yum_bucket_name       = "mydbops-yum-repo-1"

# ECR
ecr_repository_name = "mydbops/pg-build"

# GPG signing key
# Get key ID: gpg --list-secret-keys --keyid-format LONG
# Get base64 key: gpg --export-secret-keys --armor YOUR_KEY_ID | base64 -w0
gpg_key_id          = "25C0FD60E1032324"
gpg_private_key_b64 = ""   # set via TF_VAR_gpg_private_key_b64 env var

# Pulp (leave empty to disable)
pulp_url      = ""
pulp_password = ""

# CloudFront distribution ID (leave empty to skip CDN invalidation)
cloudfront_distribution_id = ""

# PG versions to create pipelines for
pg_versions = ["14", "15", "16", "17"]

build_env = "staging"
