# Pipeline Quickstart — End-to-End Setup

> From zero to packages in S3. Every step in order.

---

## 1. Prerequisites

```bash
# Tools required locally
docker, git, aws cli, python3, curl

# AWS setup (one-time, done by infra team)
# - CodePipeline per PG major (pg-platform-pkg-pg14, etc.)
# - CodeBuild projects with privileged_mode = true (Docker-in-Docker)
# - ECR repo: pg-platform/pg-build with build images pushed
# - SSM Parameters:
#     /pg-platform/cicd/build/S3_BUCKET
#     /pg-platform/cicd/build/BUILD_ENV
#     /pg-platform/cicd/ecr/account_id
#     /pg-platform/cicd/ecr/region
# - Secrets Manager:
#     pg-platform/cicd/gpg-signing-key  (base64 GPG private key)
# - S3 buckets: pg-platform-cicd-artifacts (staging + production paths)

# Clone both repos side by side
git clone github.com/pg-platform/pg-platform.git
git clone github.com/pg-platform/pg-packaging.git
cd pg-platform
```

---

## 2. Scaffold the Package

```bash
./scripts/new-package.sh \
  --name postgresql-14-pgvector \
  --version 0.7.4 \
  --pg 14 \
  --packages-dir ../pg-packaging \
  --source-url "https://github.com/pgvector/pgvector/archive/refs/tags/v0.7.4.tar.gz" \
  --description "Vector similarity search for PostgreSQL"
```

This creates `pg-packaging/packages/postgresql-14-pgvector/` with all required files.

---

## 3. Fill in the Package Definition

**a) Get the SHA256:**
```bash
curl -sL https://github.com/pgvector/pgvector/archive/refs/tags/v0.7.4.tar.gz | sha256sum
```
Paste the hex value into `METADATA.yml` → `source_sha256`.

**b) Edit generated files:**

| File | What to fill |
|------|-------------|
| `METADATA.yml` | `source_sha256` (from above) |
| `debian/main/debian/control` | `Build-Depends` — add build deps |
| `debian/main/debian/rules` | `./configure` flags |
| `rpm/main/postgresql-14-pgvector.spec` | `%build`, `%install`, `%files` |

**c) Enable one target in `build.yml`:**
```yaml
- os: ubuntu
  release: 22
  arch: [amd64]
  enabled: true   # start with just this one
```

---

## 4. Validate Locally

```bash
./scripts/lint.sh \
  --package postgresql-14-pgvector \
  --packages-dir ../pg-packaging
```

All `[FAIL]` items must be resolved. `[WARN]` items are acceptable.

---

## 5. Test Build Locally (optional but recommended)

```bash
./scripts/build-package.sh \
  --package postgresql-14-pgvector \
  --packages-dir ../pg-packaging \
  --s3-bucket pg-platform-cicd-artifacts \
  --env staging \
  --os ubuntu --release 22 --arch amd64
```

On success, the `.deb` is uploaded to:
```
s3://pg-platform-cicd-artifacts/staging/packages/postgresql-14-pgvector/0.7.4-1/ubuntu-22-amd64/
```

---

## 6. Enable Remaining Targets

Once the test build passes, open `build.yml` and enable all targets you want:
```yaml
- os: ubuntu
  release: 22
  arch: [amd64, arm64]
  enabled: true

- os: epel
  release: 9
  arch: [x86_64, aarch64]
  enabled: true
# ... etc
```

Re-run lint to confirm everything still passes.

---

## 7. Push to Remote Packaging Repo

```bash
cd ../pg-packaging

# Make sure you're on the correct pg branch
git checkout pg14

git add packages/postgresql-14-pgvector/
git commit -m "postgresql-14-pgvector: initial packaging 0.7.4"
git push origin pg14
```

---

## 8. Tag to Trigger the Pipeline

```bash
# Format: pg{major}/{package-name}-{version}-{revision}
git tag pg14/postgresql-14-pgvector-0.7.4-1
git push origin pg14/postgresql-14-pgvector-0.7.4-1
```

This tag push fires an **EventBridge rule → CodePipeline** for pg14.

> **RC builds** (staging only, skips manual approval gate):
> ```bash
> git tag pg14/postgresql-14-pgvector-0.7.4-1-rc1
> git push origin pg14/postgresql-14-pgvector-0.7.4-1-rc1
> ```

---

## 9. Pipeline Runs Automatically

```
Source  →  ParseTag (Lambda)  →  Build (4 parallel CodeBuild jobs)
  ↓
ubuntu-amd64   ubuntu-arm64   rpm-amd64   rpm-arm64

Each job:
  ECR login → download tarball → Docker build → validate → GPG sign → S3 upload

S3 staging path:
  s3://pg-platform-cicd-artifacts/staging/packages/postgresql-14-pgvector/0.7.4-1/{target}/
```

Monitor in AWS Console → **CodePipeline → pg-platform-pkg-pg14**.

---

## 10. Test Stage (automatic)

CodeBuild pulls each package from staging S3, installs it in a clean distro
container, and verifies `postgres --version`. Failures block promotion.

---

## 11. Update Staging Repo Metadata (automatic)

`reprepro` (APT) and `createrepo_c` (YUM) regenerate repository indexes
and upload them to S3. The staging APT/YUM repo is now installable.

---

## 12. Approve → Promote to Production

1. In CodePipeline, click **Review → Approve** after verifying staging.
2. The Promote stage **copies** staging → production (no rebuild).
3. Repo metadata regenerated for production.
4. If `PULP_URL` is set, Pulp syncs automatically.

**Final S3 paths:**
```
s3://pg-platform-cicd-artifacts/production/packages/postgresql-14-pgvector/0.7.4-1/
  ubuntu-22-amd64/postgresql-14-pgvector_0.7.4-1_amd64.deb
  ubuntu-22-amd64/postgresql-14-pgvector_0.7.4-1_amd64.deb.sha256
  epel-9-x86_64/postgresql-14-pgvector-0.7.4-1.x86_64.rpm
  epel-9-x86_64/postgresql-14-pgvector-0.7.4-1.x86_64.rpm.sha256
  ... (all enabled targets)
```

---

## Version Bump Workflow (subsequent releases)

```bash
cd pg-platform

# 1. Bump version files atomically
./scripts/bump-version.sh \
  --package postgresql-14-pgvector \
  --version 0.8.0 \
  --change "Upgrade to pgvector 0.8.0" \
  --packages-dir ../pg-packaging

# 2. Fill the new SHA256
curl -sL <new-tarball-url> | sha256sum
# → paste into METADATA.yml source_sha256

# 3. Commit, push, tag (same as steps 7–8)
cd ../pg-packaging
git add packages/postgresql-14-pgvector/
git commit -m "postgresql-14-pgvector: upgrade to 0.8.0"
git push origin pg14
git tag pg14/postgresql-14-pgvector-0.8.0-1
git push origin pg14/postgresql-14-pgvector-0.8.0-1
```

---

## Quick Reference

| Script | Purpose |
|--------|---------|
| `new-package.sh` | Scaffold package files from templates |
| `lint.sh` | Validate before pushing |
| `build-package.sh` | Local test build → S3 |
| `bump-version.sh` | Atomic version bump across all files |
| `backport.sh` | Cherry-pick fix across pg* branches |
| `new-pg-version.sh` | Bootstrap new PG major branch |
| `eol.sh` | Archive and retire EOL version |
