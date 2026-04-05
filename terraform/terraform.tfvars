# Copy from terraform.tfvars.example and fill in real values
# Do NOT commit this file

aws_region     = "ap-south-1"
aws_account_id = ""

github_connection_arn = ""

packaging_repo = "pg-platform/pg-packaging"
platform_repo  = "pg-platform/pg-platform"

artifacts_bucket_name = "pg-platform-cicd-artifacts"
apt_bucket_name       = "pg-platform-apt-repo"
yum_bucket_name       = "pg-platform-yum-repo"

ecr_repository_name = "pg-platform/pg-build"

gpg_key_id          = ""
gpg_private_key_b64 = ""

pulp_url      = ""
pulp_password = ""

cloudfront_distribution_id = ""

pg_versions = ["14", "15", "16", "17"]

build_env = "staging"
