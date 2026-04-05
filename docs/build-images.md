# Build Images — Docker Management

Build images live in ECR (`pg-platform/pg-build`) and are pulled by `build-package.sh`
at runtime. They are maintained separately from build scripts — never work around
a stale image by editing the build script.

---

## Image Map

| ECR Tag | Dockerfile | Used for |
|---------|-----------|---------|
| `ubuntu-20.04-amd64` | `Dockerfile.ubuntu` | Ubuntu 20 amd64 .deb |
| `ubuntu-22.04-amd64` | `Dockerfile.ubuntu` | Ubuntu 22 amd64 .deb |
| `ubuntu-22.04-arm64` | `Dockerfile.ubuntu` | Ubuntu 22 arm64 .deb |
| `ubuntu-24.04-amd64` | `Dockerfile.ubuntu` | Ubuntu 24 amd64 .deb |
| `ubuntu-24.04-arm64` | `Dockerfile.ubuntu` | Ubuntu 24 arm64 .deb |
| `el8-x86_64`         | `Dockerfile.el`     | EPEL 8 x86_64 .rpm  |
| `el8-aarch64`        | `Dockerfile.el`     | EPEL 8 aarch64 .rpm |
| `el9-x86_64`         | `Dockerfile.el`     | EPEL 9 x86_64 .rpm  |
| `el9-aarch64`        | `Dockerfile.el`     | EPEL 9 aarch64 .rpm |
| `el10-x86_64`        | `Dockerfile.el`     | EPEL 10 x86_64 .rpm |
| `fedora-42-x86_64`   | `Dockerfile.fedora` | Fedora 42 .rpm      |
| `fedora-43-x86_64`   | `Dockerfile.fedora` | Fedora 43 .rpm      |

Each image has PostgreSQL dev headers for all active PG majors (14–17) pre-installed.

---

## Managing Images

All operations go through `scripts/manage-build-images.sh`.
Set ECR account + region once via env or `--account`/`--region` flags.

```bash
export ECR_ACCOUNT_ID=123456789012
export ECR_REGION=ap-south-1
```

### List — check what exists locally and in ECR

```bash
./scripts/manage-build-images.sh list
```
```
TAG                            PLATFORM       LOCAL        ECR
---                            --------       -----        ---
ubuntu-22.04-amd64             linux/amd64    present      present
ubuntu-22.04-arm64             linux/arm64    absent       present
el9-x86_64                     linux/amd64    present      present
...
```

### Build

```bash
# Build all 12 images
./scripts/manage-build-images.sh build

# Build one image
./scripts/manage-build-images.sh build --target ubuntu-22.04-amd64

# Build with specific PG versions embedded
./scripts/manage-build-images.sh build --pg-versions "14 15 16 17" --target el9-x86_64
```

### Push to ECR

```bash
# Push all
./scripts/manage-build-images.sh push

# Push one
./scripts/manage-build-images.sh push --target ubuntu-22.04-amd64
```

### Pull from ECR (for local dev or CI setup)

```bash
./scripts/manage-build-images.sh pull
./scripts/manage-build-images.sh pull --target el9-x86_64
```

### Scan for vulnerabilities

```bash
# Trigger ECR scan on all images
./scripts/manage-build-images.sh scan

# Scan one image
./scripts/manage-build-images.sh scan --target ubuntu-22.04-amd64

# View results
aws ecr describe-image-scan-findings \
  --repository-name pg-platform/pg-build \
  --image-id imageTag=ubuntu-22.04-amd64
```

### ECR Login only

```bash
./scripts/manage-build-images.sh login
```

### Dry-run (preview commands without executing)

```bash
./scripts/manage-build-images.sh build --dry-run
./scripts/manage-build-images.sh push  --dry-run --target el9-x86_64
```

---

## Initial Setup (first time)

```bash
# 1. Create the ECR repository
aws ecr create-repository \
  --repository-name pg-platform/pg-build \
  --region ap-south-1 \
  --image-scanning-configuration scanOnPush=true

# 2. Enable multi-arch builds (required for arm64 images on amd64 host)
docker buildx create --use --name pg-platform-builder

# 3. Build and push all images
export ECR_ACCOUNT_ID=123456789012
./scripts/manage-build-images.sh build
./scripts/manage-build-images.sh push
```

---

## When to Rebuild Images

| Situation | Action |
|-----------|--------|
| New PG major version released | Rebuild all images with updated `--pg-versions` |
| New OS release (Ubuntu 26, EL 10, Fedora 44) | Add new Dockerfile or `ARG`, rebuild, add to manifest in `manage-build-images.sh` |
| Build dependency changed (e.g. new `libssl`) | Rebuild affected images, push |
| Routine refresh / security patches | Rebuild all (`build` + `push`), then `scan` |
| Build fails with "package not found" | Check PGDG repo for that OS, rebuild image |

After rebuilding and pushing, the next pipeline run picks up the new image automatically — no changes to buildspecs or scripts required.

---

## Adding a New Build Target

1. Add a `Dockerfile` section or new `ARG` value (e.g. `UBUNTU_VERSION=26.04`)
2. Register the new tag in the `_reg` block inside `manage-build-images.sh`
3. Build and push: `./scripts/manage-build-images.sh build --target ubuntu-26.04-amd64`
4. Follow the 7-step checklist in `CLAUDE.md` (update buildspec + templates + docs)

---

## Dockerfile Contents

All images include:

| Component | Purpose |
|-----------|---------|
| Build toolchain (`gcc`, `make`, `debhelper`/`rpmbuild`) | Compile packages |
| PostgreSQL PGDG repo + dev headers for PG 14–17 | Link extensions against correct PG |
| `dpkg-sig` / `rpm-sign` | GPG package signing |
| `lintian` / `rpmlint` | Post-build validation |
| `python3` + `python3-yaml` | YAML parsing in build scripts |
| AWS CLI v2 | S3 uploads from inside the container |
| `curl`, `jq`, `git` | General build utilities |
