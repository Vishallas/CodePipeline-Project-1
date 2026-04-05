# Adding a New Package

This guide walks through adding a new extension or tool to the Pg-platform PostgreSQL packaging system.

## Prerequisites

- Both repos cloned side by side:
  ```
  pg-platform/     ← build infrastructure (this repo)
  pg-packaging/    ← package definitions
  ```
- Docker running locally (for local test builds)
- AWS credentials with S3 write access to a dev/staging bucket
- CodeBuild projects must have `privileged_mode = true` for Docker-in-Docker

## Step 1: Scaffold the package

Run `new-package.sh` from inside `pg-platform/`:

```bash
./scripts/new-package.sh \
  --name postgresql-14-pgvector \
  --version 0.7.4 \
  --pg 14 \
  --packages-dir ../pg-packaging \
  --source-url "https://github.com/pgvector/pgvector/archive/refs/tags/v0.7.4.tar.gz" \
  --description "Open-source vector similarity search for PostgreSQL"
```

This creates in `pg-packaging/packages/postgresql-14-pgvector/`:
- `METADATA.yml` — package metadata
- `build.yml` — build targets (all disabled by default)
- `debian/main/debian/control` — build dependencies and package metadata
- `debian/main/debian/rules` — build instructions
- `debian/main/debian/changelog` — version history
- `debian/main/debian/copyright` — license info
- `rpm/main/postgresql-14-pgvector.spec` — RPM spec file
- `tests/sql/00_version_check.sql` — basic test

## Step 2: Fill in the generated files

### METADATA.yml

```yaml
source_url:    "https://..."   # Set the real download URL
source_sha256: ""              # Fill this (see below)
description:   "..."           # One-line description
```

To get the SHA256:
```bash
curl -sL https://your-tarball-url | sha256sum
```
Then paste the hex value into `source_sha256`.

### debian/main/debian/control

Add real build dependencies to `Build-Depends:`. For a PostgreSQL extension:
```
Build-Depends:
 debhelper-compat (= 13),
 postgresql-server-dev-14,
 libreadline-dev,
 ...
```

### debian/main/debian/rules

Add configure flags and any `dh_*` overrides needed for the specific package.

### rpm/main/postgresql-14-pgvector.spec

Fill in `%build`, `%install`, and `%files` sections.

## Step 3: Enable a test target

In `build.yml`, enable one target to start:

```yaml
- os: ubuntu
  release: 22
  arch: [amd64]
  enabled: true   # ← enable this one first
```

## Step 4: Validate

```bash
./scripts/lint.sh \
  --package postgresql-14-pgvector \
  --packages-dir ../pg-packaging
```

Fix any `[FAIL]` items. `[WARN]` items (like missing sha256) are acceptable during development.

## Step 5: Test one target locally

```bash
./scripts/build-package.sh \
  --package postgresql-14-pgvector \
  --packages-dir ../pg-packaging \
  --s3-bucket pg-platform-cicd-artifacts-dev \
  --env staging \
  --os ubuntu --release 22 --arch amd64
```

Docker must be running. AWS credentials with S3 write access are required.
The script uploads directly to S3 — there is no local `dist/` directory.

## Step 6: Enable remaining targets and submit

Once the test target builds successfully:

1. Enable additional targets in `build.yml`
2. Re-run lint with `--strict` to catch any warnings
3. Open a PR to the appropriate `pgN` branch in `pg-packaging`
4. After merge, tag to trigger the pipeline (see [releasing.md](releasing.md))

## Tag format

```
pg14/postgresql-14-pgvector-0.7.4-1
     ^^^^^^^^^^^^^^^^^^^^^^^^ ^^^^^ ^
     package name             version revision
```

## Notes

- **Docker-in-Docker**: CodeBuild projects must have `privileged_mode = true`
- **ECR images**: Build images are pulled from ECR. If a build fails with "image not found",
  the image needs to be built and pushed separately.
- **Dist overlays**: Place distro-specific debian files in `debian/{codename}/` (e.g.
  `debian/jammy/`) to override the `debian/main/debian/` defaults for that Ubuntu release.
