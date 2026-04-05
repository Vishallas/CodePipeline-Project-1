# pg-platform

Build infrastructure for PostgreSQL packaging. Produces `.deb` and `.rpm` packages for PostgreSQL and its extensions across Ubuntu 20/22/24, EPEL 8/9/10, and Fedora 42/43.

## Repositories

This project uses two repos:

| Repo | Purpose |
|------|---------|
| `pg-platform` (this repo) | Build scripts, buildspecs, Terraform, Docker infrastructure |
| `pg-packaging` | Package definitions — one branch per PG major version (`pg14`, `pg15`, `pg16`, `pg17`), plus `tools` for version-agnostic packages |

## How it works

1. Push a git tag to `pg-packaging` (e.g. `pg16/pgvector-0.7.4-1`)
2. EventBridge triggers the matching CodePipeline (`pg-platform-pkg-pg16`)
3. ParseTag stage parses the tag, validates it against `METADATA.yml`
4. Build stage runs 4 parallel CodeBuild jobs (ubuntu-amd64, ubuntu-arm64, rpm-amd64, rpm-arm64)
5. Each job calls `scripts/build-package.sh`, which pulls Docker images, builds packages, and uploads directly to S3
6. Test stage installs the packages in clean containers
7. Repo metadata is regenerated (reprepro for APT, createrepo_c for YUM)
8. Manual approval gate before promoting to production
9. Promote stage copies packages from `staging/` to `production/` in S3

## Tag format

```
pg{major}/{package-name}-{version}-{revision}
tools/{package-name}-{version}-{revision}

Examples:
  pg16/pgvector-0.7.4-1
  pg16/postgresql-16.6-1
  pg15/pgaudit-15.0-2
  tools/pgbouncer-1.22.0-1
  pg16/pgvector-0.8.0-1-rc1   # rc: staging only, skips production approval
```

## Directory structure

```
pg-platform/
├── scripts/
│   ├── build-package.sh       # Main build entry point
│   ├── lint.sh                # Validates METADATA.yml and build.yml
│   ├── new-package.sh         # Scaffolds a new package
│   ├── bump-version.sh        # Version bump with audit trail
│   ├── backport.sh            # Cherry-pick across pg* branches
│   ├── new-pg-version.sh      # Creates a new pg{N} branch
│   ├── eol.sh                 # Archives an EOL PG version
│   └── lib/
│       ├── common.sh
│       ├── deb.sh
│       └── rpm.sh
├── buildspec/
│   ├── buildspec-parse-tag.yml
│   ├── buildspec-ubuntu-amd64.yml
│   ├── buildspec-ubuntu-arm64.yml
│   ├── buildspec-rpm-amd64.yml
│   ├── buildspec-rpm-arm64.yml
│   ├── buildspec-repo-updater.yml
│   └── buildspec-test.yml
├── terraform/
│   ├── main.tf
│   ├── variables.tf
│   ├── outputs.tf
│   ├── terraform.tfvars.example
│   └── modules/
│       ├── pg-pipeline/       # One CodePipeline per PG major version
│       └── repo-updater/      # APT/YUM metadata regeneration
├── config/
│   ├── pg-versions.yml        # PG version registry
│   └── repos.yml              # S3/ECR/GPG config
├── docker/
│   ├── Dockerfile.ubuntu
│   ├── Dockerfile.el
│   └── Dockerfile.fedora
└── templates/                 # Scaffolding templates for new packages
```

## Local development

Clone both repos side by side:

```bash
mkdir ~/pg
cd ~/pg
git clone https://github.com/pg-platform/pg-platform
git clone https://github.com/pg-platform/pg-packaging
```

Build a specific package (uploads to S3 on success):

```bash
./scripts/build-package.sh \
  --package postgresql-16-pgvector \
  --packages-dir ../pg-packaging \
  --s3-bucket pg-platform-cicd-artifacts \
  --env staging
```

Build one specific target:

```bash
./scripts/build-package.sh \
  --package postgresql-16-pgvector \
  --packages-dir ../pg-packaging \
  --s3-bucket pg-platform-cicd-artifacts \
  --env staging \
  --os ubuntu --release 22 --arch amd64
```

Scaffold a new package:

```bash
./scripts/new-package.sh \
  --name postgresql-16-pgpartman \
  --version 5.0.0 \
  --pg 16 \
  --packages-dir ../pg-packaging
```

## Terraform

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
# fill in terraform.tfvars
terraform init
terraform apply
```

Required variables: `aws_account_id`, `github_connection_arn`. All others have defaults.

## S3 path structure

```
s3://{bucket}/{env}/packages/{package-name}/{version}/
  ubuntu-20-amd64/{package}.deb
  ubuntu-22-amd64/{package}.deb
  ubuntu-22-arm64/{package}.deb
  ubuntu-24-amd64/{package}.deb
  ubuntu-24-arm64/{package}.deb
  epel-8-x86_64/{package}.rpm
  epel-9-x86_64/{package}.rpm
  epel-10-x86_64/{package}.rpm
  f42-x86_64/{package}.rpm
  ...
```

## Supported targets

| Target | Docker image |
|--------|-------------|
| ubuntu-20-amd64 | `pg-platform/pg-build:ubuntu-20.04-amd64` |
| ubuntu-22-amd64 | `pg-platform/pg-build:ubuntu-22.04-amd64` |
| ubuntu-22-arm64 | `pg-platform/pg-build:ubuntu-22.04-arm64` |
| ubuntu-24-amd64 | `pg-platform/pg-build:ubuntu-24.04-amd64` |
| ubuntu-24-arm64 | `pg-platform/pg-build:ubuntu-24.04-arm64` |
| epel-8-x86_64 | `pg-platform/pg-build:el8-x86_64` |
| epel-8-aarch64 | `pg-platform/pg-build:el8-aarch64` |
| epel-9-x86_64 | `pg-platform/pg-build:el9-x86_64` |
| epel-9-aarch64 | `pg-platform/pg-build:el9-aarch64` |
| epel-10-x86_64 | `pg-platform/pg-build:el10-x86_64` |
| f42-x86_64 | `pg-platform/pg-build:fedora-42-x86_64` |
| f43-x86_64 | `pg-platform/pg-build:fedora-43-x86_64` |
