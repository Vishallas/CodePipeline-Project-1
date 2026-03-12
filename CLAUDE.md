# CLAUDE.md — mydbops-pg-platform

This file tells Claude exactly how this repository works, what every component
does, and how to make changes correctly. Read this fully before touching anything.

---

## What this repository is

`mydbops-pg-platform` is the **build infrastructure** for Mydbops PostgreSQL
packaging. It contains no package definitions — those live in a separate repo
(`mydbops-pg-packages`, one branch per PG major version: pg14, pg15, pg16, pg17,
plus a `tools` branch for PG-version-agnostic tools like pgbouncer and pgbackrest).

This repo contains:
- The custom build script (`scripts/build-package.sh`) that drives all packaging
- AWS CodeBuild buildspecs (one per OS/arch target)
- Terraform for CodePipeline infrastructure (one pipeline per PG version + one for tools)
- A Lambda that parses git tags into pipeline variables
- Shared shell libraries
- Config files (pg-versions.yml, repos.yml)
- Scaffolding templates for new packages

---

## The custom build script

**File:** `scripts/build-package.sh`

This is the single entry point for all package builds. It is called by every
CodeBuild buildspec and can also be run locally for development.

### How it works

1. Reads build targets from the package's `build.yml` config file (default)
2. CLI args (`--os`, `--release`, `--arch`) override `build.yml` for that run only —
   if any CLI arg is provided, only that specific target is built, `build.yml` is ignored
3. Downloads the source tarball from the URL in `METADATA.yml` (`.package.source_url`)
   fresh on every build run — there is no local cache, CodeBuild environments are ephemeral
4. For each target: pulls the correct Docker image for that OS/release/arch,
   mounts the tarball and packaging files into the container, runs the build inside it
5. Uploads the resulting packages directly to S3 on success — there is no intermediate
   `dist/` directory and no separate publish step for packages

### Invocation

```bash
# Default — reads all enabled targets from build.yml, uploads to S3
scripts/build-package.sh \
  --package postgresql-16-pgvector \
  --packages-dir ../mydbops-pg-packages \
  --s3-bucket mydbops-cicd-artifacts \
  --env staging

# Override to one specific target (build.yml is ignored when CLI args given)
scripts/build-package.sh \
  --package postgresql-16-pgvector \
  --packages-dir ../mydbops-pg-packages \
  --s3-bucket mydbops-cicd-artifacts \
  --env staging \
  --os ubuntu --release 22 --arch amd64

# Build all packages (manual trigger mode — iterates all packages in packages-dir)
scripts/build-package.sh \
  --all \
  --packages-dir ../mydbops-pg-packages \
  --s3-bucket mydbops-cicd-artifacts \
  --env staging
```

The `--env` flag controls which S3 path prefix is used:
- `staging`    → `s3://{bucket}/staging/packages/{pkg}/{version}/{target}/`
- `production` → `s3://{bucket}/production/packages/{pkg}/{version}/{target}/`

There is no `--dry-run` flag — use `--os/--release/--arch` to scope to one
target when testing locally to limit what gets built and uploaded.

### Source tarball handling

The script always downloads the tarball fresh using the URL in `METADATA.yml`
(`.package.source_url`). There is no local cache — CodeBuild environments are
ephemeral and start clean every run.

If the URL is unreachable the build fails immediately with a clear error before
any Docker container is started. The script does not fall back to a local file.

Tarball download happens once per `build-package.sh` invocation, before the
target loop. All targets for that package share the same downloaded tarball.

### Output — direct S3 upload

The script uploads packages directly to S3 after each successful target build.
There is no intermediate `dist/` directory. The upload happens inside the build
loop, per target, immediately after the Docker container exits successfully.

S3 path structure:
```
s3://{bucket}/{env}/packages/{package-name}/{version}/
  ubuntu-20-amd64/{package}.deb
  ubuntu-20-amd64/{package}.deb.sha256
  ubuntu-22-amd64/{package}.deb
  ubuntu-22-amd64/{package}.deb.sha256
  ubuntu-22-arm64/{package}.deb
  ubuntu-22-arm64/{package}.deb.sha256
  ubuntu-24-amd64/{package}.deb
  ubuntu-24-amd64/{package}.deb.sha256
  ubuntu-24-arm64/{package}.deb
  ubuntu-24-arm64/{package}.deb.sha256
  epel-8-x86_64/{package}.rpm
  epel-8-x86_64/{package}.rpm.sha256
  epel-8-aarch64/{package}.rpm
  epel-8-aarch64/{package}.rpm.sha256
  epel-9-x86_64/{package}.rpm
  epel-9-x86_64/{package}.rpm.sha256
  epel-9-aarch64/{package}.rpm
  epel-9-aarch64/{package}.rpm.sha256
  epel-10-x86_64/{package}.rpm
  epel-10-x86_64/{package}.rpm.sha256
  f42-x86_64/{package}.rpm
  f42-x86_64/{package}.rpm.sha256
  f43-x86_64/{package}.rpm
  f43-x86_64/{package}.rpm.sha256
```

If one target fails, the script logs the error, skips uploading that target,
and continues with remaining targets. It exits non-zero at the end if any
target failed. This means a partial upload is possible — failed targets simply
have no file in S3 for that run.

The APT/YUM repo metadata regeneration (reprepro, createrepo_c) is handled by
a separate CodeBuild project triggered after the build stage, not by this script.

### Docker images used per target

| Target             | Docker image                                      |
|--------------------|---------------------------------------------------|
| ubuntu-20-amd64    | mydbops/pg-build:ubuntu-20.04-amd64               |
| ubuntu-22-amd64    | mydbops/pg-build:ubuntu-22.04-amd64               |
| ubuntu-22-arm64    | mydbops/pg-build:ubuntu-22.04-arm64               |
| ubuntu-24-amd64    | mydbops/pg-build:ubuntu-24.04-amd64               |
| ubuntu-24-arm64    | mydbops/pg-build:ubuntu-24.04-arm64               |
| epel-8-x86_64      | mydbops/pg-build:el8-x86_64                       |
| epel-8-aarch64     | mydbops/pg-build:el8-aarch64                      |
| epel-9-x86_64      | mydbops/pg-build:el9-x86_64                       |
| epel-9-aarch64     | mydbops/pg-build:el9-aarch64                      |
| epel-10-x86_64     | mydbops/pg-build:el10-x86_64                      |
| f42-x86_64         | mydbops/pg-build:fedora-42-x86_64                 |
| f43-x86_64         | mydbops/pg-build:fedora-43-x86_64                 |

These images are maintained separately. If a build fails because an image is
missing or outdated, rebuild and push the image — do not modify the build script
to work around a stale image.

---

## The build.yml config file

Every package in `mydbops-pg-packages` has a `build.yml` alongside its
`METADATA.yml`. This is what the build script reads to know which targets to build.

**Location in packages repo:**
`packages/{package-name}/build.yml`

**Format:**
```yaml
# packages/postgresql-16-pgvector/build.yml
targets:
  - os: ubuntu
    release: 20
    arch: [amd64]
    enabled: true
  - os: ubuntu
    release: 22
    arch: [amd64, arm64]
    enabled: true
  - os: ubuntu
    release: 24
    arch: [amd64, arm64]
    enabled: true
  - os: epel
    release: 8
    arch: [x86_64, aarch64]
    enabled: true
  - os: epel
    release: 9
    arch: [x86_64, aarch64]
    enabled: true
  - os: epel
    release: 10
    arch: [x86_64]
    enabled: true
  - os: fedora
    release: 42
    arch: [x86_64]
    enabled: false    # not yet tested
  - os: fedora
    release: 43
    arch: [x86_64]
    enabled: false
```

**Rules:**
- `enabled: false` means the build script skips that target silently
- CLI `--os`, `--release`, `--arch` override `build.yml` for that run only
- `build.yml` is committed in the packages repo alongside METADATA.yml
- When adding a new target OS, add it to `build.yml` and set `enabled: false`
  until it is tested, then flip to `true` in a separate PR

---

## Repository structure

```
mydbops-pg-platform/
│
├── CLAUDE.md                         ← you are here
│
├── scripts/
│   ├── build-package.sh              ← THE build script — builds + uploads to S3 directly
│   ├── lint.sh                       ← validates METADATA.yml + build.yml + spec/control
│   ├── new-package.sh                ← scaffolds a new package in the packages repo
│   ├── bump-version.sh               ← safe version bump with full audit trail
│   ├── backport.sh                   ← cherry-pick fixes across pg* branches
│   ├── new-pg-version.sh             ← creates a new pg{N} branch from an existing one
│   ├── eol.sh                        ← archives and retires an EOL PG version
│   └── lib/
│       ├── common.sh                 ← logging, yaml helpers, gpg utils, shared functions
│       ├── deb.sh                    ← .deb assembly helpers (called by build-package.sh)
│       └── rpm.sh                    ← .rpm assembly helpers (called by build-package.sh)
│
├── buildspec/
│   │
│   │   Each buildspec covers ONE arch group on ONE compute type.
│   │   The buildspec's only job is to set up the environment and call
│   │   build-package.sh. All build logic stays in the script, not here.
│   │
│   ├── buildspec-ubuntu-amd64.yml    ← Ubuntu 20/22/24 on x86_64 CodeBuild
│   ├── buildspec-ubuntu-arm64.yml    ← Ubuntu 22/24 on ARM CodeBuild
│   ├── buildspec-rpm-amd64.yml       ← EPEL 8/9/10 + Fedora 42/43 on x86_64
│   ├── buildspec-rpm-arm64.yml       ← EPEL 8/9 on aarch64
│   └── buildspec-test.yml            ← smoke tests after build
│
├── terraform/
│   ├── main.tf                       ← root: S3, IAM, Lambda, one module per PG version
│   ├── variables.tf
│   ├── outputs.tf
│   └── modules/
│       ├── pg-pipeline/
│       │   ├── main.tf               ← one full CodePipeline per PG version
│       │   ├── variables.tf
│       │   └── outputs.tf
│       └── repo-updater/
│           └── main.tf               ← APT/YUM metadata regeneration
│
├── lambda/
│   └── tag_parser.py                 ← parses git tag → SSM params → pipeline variables
│
├── config/
│   ├── pg-versions.yml               ← master registry: all PG versions, EOL dates,
│   │                                   supported extensions, pipeline_enabled flags
│   └── repos.yml                     ← APT/YUM S3 buckets, CloudFront, GPG key IDs
│
├── templates/                        ← used by new-package.sh to scaffold new packages
│   ├── METADATA.yml.tpl
│   ├── build.yml.tpl                 ← default build.yml with all targets disabled
│   ├── debian/
│   │   ├── control.tpl
│   │   ├── rules.tpl
│   │   ├── changelog.tpl
│   │   └── copyright.tpl
│   └── rpm/
│       └── package.spec.tpl
│
└── docs/
    ├── adding-a-package.md
    ├── releasing.md
    ├── branch-strategy.md
    └── eol-process.md
```

---

## CodePipeline architecture

### Two-repo source model

Every pipeline has two source inputs:

| Artifact name      | Repo                   | Branch   | Contains                        |
|--------------------|------------------------|----------|---------------------------------|
| `packages_source`  | mydbops-pg-packages    | pg{N}    | METADATA.yml, build.yml, debian/, rpm/ |
| `platform_source`  | mydbops-pg-platform    | main     | scripts/, buildspec/, terraform/ |

Inside every CodeBuild job:
```bash
PACKAGES_DIR="$CODEBUILD_SRC_DIR"               # packages repo
PLATFORM_DIR="$CODEBUILD_SRC_DIR_platform_source"  # platform repo
SCRIPTS="$PLATFORM_DIR/scripts"
```

### Pipeline stages

```
Stage 1 │ Source
        │   packages_source  → mydbops-pg-packages branch pg{N}
        │   platform_source  → mydbops-pg-platform branch main
        │
Stage 2 │ ParseTag  (Lambda: tag_parser.py)
        │   Reads git tag e.g. pg16/pgvector-0.7.4-1
        │   Validates version matches METADATA.yml
        │   Writes to SSM: PACKAGE_NAME, PACKAGE_VERSION, PG_MAJOR, GIT_TAG
        │   Returns pipeline variables: #{ParseVars.PACKAGE_NAME} etc.
        │
Stage 3 │ Build  (4 parallel CodeBuild jobs, run_order=1)
        │   ubuntu-amd64  → buildspec-ubuntu-amd64.yml
        │   ubuntu-arm64  → buildspec-ubuntu-arm64.yml
        │   rpm-amd64     → buildspec-rpm-amd64.yml
        │   rpm-arm64     → buildspec-rpm-arm64.yml
        │
        │   Each job calls:
        │   $SCRIPTS/build-package.sh \
        │     --package $PACKAGE_NAME \
        │     --packages-dir $PACKAGES_DIR \
        │     --s3-bucket $S3_BUCKET \
        │     --env staging
        │
        │   build-package.sh reads build.yml, downloads the tarball from
        │   METADATA.yml source_url, pulls Docker images, builds packages,
        │   and uploads directly to S3 under s3://{bucket}/staging/packages/
        │   No dist/ directory. No separate publish step.
        │
Stage 4 │ Test
        │   Runs tests/test_install.sh from packages_source
        │   Tests pull the package from S3 staging path to install and verify
        │
Stage 5 │ Update Staging Repo Metadata
        │   CodeBuild: repo-updater project
        │   Runs reprepro (APT) and createrepo_c (YUM) against staging S3 paths
        │   Clients pointing at staging repo can now install the package
        │
Stage 6 │ Approve  (manual gate in AWS Console)
        │   Custom message shows package name + version from #{ParseVars.*}
        │
Stage 7 │ Promote to Production
        │   CodeBuild: copies packages from
        │     s3://{bucket}/staging/packages/{pkg}/{version}/
        │   to
        │     s3://{bucket}/production/packages/{pkg}/{version}/
        │   Then runs reprepro + createrepo_c against production S3 paths
        │   This is a copy, not a rebuild — exact same binaries go to production
```

### Trigger model

| Trigger | What happens |
|---------|-------------|
| Git tag `pg16/pgvector-0.7.4-1` on packages repo | EventBridge starts `mydbops-pkg-pg16` only |
| Git tag `tools/pgbouncer-1.22.0-1` on packages repo | EventBridge starts `mydbops-pkg-tools` only |
| Manual trigger (AWS Console or CLI) | Starts selected pipeline, builds ALL enabled packages |
| Push to any branch | Nothing — branch pushes never trigger builds |
| Push to platform repo main | Nothing — platform changes take effect on next tag trigger |

### Tag format

```
pg{major}/{package-short-name}-{version}-{revision}
tools/{package-name}-{version}-{revision}

Examples:
  pg16/pgvector-0.7.4-1
  pg16/postgresql-16.6-1
  pg15/pgaudit-15.0-2
  tools/pgbouncer-1.22.0-1
  pg16/pgvector-0.8.0-1-rc1   ← rc tag: staging only, skips prod approval
```

---

## What lives where — decision table

| Change type | Repo | Branch | Notes |
|-------------|------|--------|-------|
| Add/update build target in build.yml | pg-packages | pg16 etc. | PR to the right pg branch |
| Fix a bug in build-package.sh | pg-platform | main | Affects all PG versions on next run |
| Add a new Docker build image | pg-platform | main | Update image table in this file too |
| Add a new OS target (e.g. ubuntu-26) | pg-platform | main | Add buildspec entry + image + update CLAUDE.md |
| Change EPEL version (e.g. add epel-10) | pg-platform | main | Add to image table, buildspec, templates/build.yml.tpl |
| New extension for pg16 | pg-packages | pg16 | Use new-package.sh |
| Bump extension version on pg16 | pg-packages | pg16 | Use bump-version.sh |
| Backport fix from pg16 to pg15 | pg-packages | pg15 | Use backport.sh |
| New PostgreSQL major version | pg-packages | new pg{N} | Use new-pg-version.sh |
| EOL a PG version | pg-platform | main | Use eol.sh, then terraform apply |
| Add a version-agnostic tool | pg-packages | tools | Same process, tools/ tag prefix |

---

## How buildspecs call the build script

Every buildspec is a thin wrapper. All logic lives in `build-package.sh`.

```yaml
# Correct pattern — buildspec calls the script, nothing else
phases:
  build:
    commands:
      - export PACKAGES_DIR="$CODEBUILD_SRC_DIR"
      - export PLATFORM_DIR="$CODEBUILD_SRC_DIR_platform_source"
      - export SCRIPTS="$PLATFORM_DIR/scripts"
      - source "$SCRIPTS/lib/common.sh"
      - |
        "$SCRIPTS/build-package.sh" \
          --package "$PACKAGE_NAME" \
          --packages-dir "$PACKAGES_DIR" \
          --s3-bucket "$S3_BUCKET" \
          --env staging \
          --os ubuntu          # scope this buildspec to ubuntu targets only
```

**Do not** put build logic in buildspecs. If you find yourself writing more than
setup + one script call in a buildspec, the logic belongs in `build-package.sh`
or a lib/ helper instead.

---

## Adding a new OS or release target

When a new OS or release needs to be supported (e.g. Ubuntu 26, EPEL 10,
Fedora 44), do all of the following — never just one:

1. **Build and push the Docker image** for the new target
2. **Add the image to the table** in this CLAUDE.md under "Docker images used per target"
3. **Add the target** to the relevant buildspec in `buildspec/`
4. **Add the target** to `templates/build.yml.tpl` with `enabled: false`
5. **Test** by running build-package.sh locally against a test package with `--os` override
6. **Update** `templates/build.yml.tpl` to `enabled: true` once confirmed working
7. **Announce** in the team so existing packages can opt in via their `build.yml`

---

## Local development setup

Both repos must be cloned side by side:

```
~/mydbops/
  mydbops-pg-packages/    ← package definitions
  mydbops-pg-platform/    ← this repo
```

Running scripts locally:

```bash
# From inside mydbops-pg-platform/
cd ~/mydbops/mydbops-pg-platform

# Build a specific package — uploads to S3 staging on success
./scripts/build-package.sh \
  --package postgresql-16-pgvector \
  --packages-dir ../mydbops-pg-packages \
  --s3-bucket mydbops-cicd-artifacts \
  --env staging

# Build only ubuntu-22-amd64 (CLI args override build.yml)
./scripts/build-package.sh \
  --package postgresql-16-pgvector \
  --packages-dir ../mydbops-pg-packages \
  --s3-bucket mydbops-cicd-artifacts \
  --env staging \
  --os ubuntu --release 22 --arch amd64

# Lint a package before PR
./scripts/lint.sh \
  --package postgresql-16-pgvector \
  --packages-dir ../mydbops-pg-packages

# Scaffold a new package (writes into packages repo)
./scripts/new-package.sh \
  --name postgresql-16-pgpartman \
  --version 5.0.0 \
  --pg 16 \
  --packages-dir ../mydbops-pg-packages

# Bump a version
./scripts/bump-version.sh \
  --package postgresql-16-pgvector \
  --version 0.8.0 \
  --change "Upgrade to upstream 0.8.0" \
  --packages-dir ../mydbops-pg-packages
```

Docker must be running locally for `build-package.sh` to work. AWS credentials
with S3 write access to the target bucket are also required locally. Use a
dedicated staging bucket for local development — never point at production.

---

## What Claude should and should not do

**Do:**
- When asked to add a new OS target, follow the 7-step checklist above exactly
- When asked to fix a build issue, look at `build-package.sh` first — that is
  where almost all build logic lives
- When asked to add a new script, put shared functions in `lib/common.sh`,
  `lib/deb.sh`, or `lib/rpm.sh` rather than duplicating them
- When modifying a buildspec, keep it as thin as possible — setup + one script call only
- When asked about a package definition (METADATA.yml, spec, control), clarify
  that those live in `mydbops-pg-packages`, not here
- When adding a new pipeline for a PG version, copy the pg-pipeline Terraform
  module pattern — one module instantiation per version in main.tf
- Remember that production promotion is a copy from staging S3 path, not a rebuild

**Do not:**
- Do not add package definitions (METADATA.yml, debian/, rpm/) to this repo
- Do not put build logic inside buildspecs — it belongs in build-package.sh
- Do not modify Docker images inline — they are maintained separately
- Do not hardcode package names, versions, or OS targets anywhere in Terraform
  or buildspecs — they come from METADATA.yml and build.yml at runtime
- Do not create a new script for something that can be a flag or function
  in an existing script
- Do not write code that reads from a `dist/` directory — packages go straight
  to S3, there is no local dist/ at any point in the pipeline
- Do not run build-package.sh locally against the production bucket

---

## Key files to read before making changes

| What you're changing | Read first |
|----------------------|-----------|
| build-package.sh | scripts/lib/common.sh, scripts/lib/deb.sh, scripts/lib/rpm.sh |
| Any buildspec | buildspec/buildspec-ubuntu-amd64.yml (as the reference pattern) |
| Terraform pipeline | terraform/modules/pg-pipeline/main.tf |
| Adding a target OS | This CLAUDE.md (the 7-step checklist above) |
| Tag parsing | lambda/tag_parser.py |
| S3 path structure | This CLAUDE.md (the "Output — direct S3 upload" section) |
| Repo metadata regeneration | terraform/modules/repo-updater/main.tf |
| EOL a version | scripts/eol.sh, config/pg-versions.yml |
