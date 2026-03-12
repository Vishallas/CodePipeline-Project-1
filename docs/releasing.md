# Releasing a Package

## Bump the version

Use `bump-version.sh` to update all version files atomically:

```bash
cd mydbops-pg-platform

./scripts/bump-version.sh \
  --package postgresql-14 \
  --version 14.22 \
  --change "Upgrade to upstream 14.22" \
  --packages-dir ../mydbops-pg-packaging
```

This updates:
- `METADATA.yml` — `version` and `revision`, clears `source_sha256`
- `debian/main/debian/changelog` — prepends new entry
- `rpm/main/*.spec` — updates `Version:`, `Release:`, and `%changelog`

The script does NOT commit. Review the diff before committing.

## Fill the SHA256

After bumping the version, set the source SHA256 in `METADATA.yml`:

```bash
curl -sL "$(grep source_url packages/postgresql-14/METADATA.yml | awk -F'"' '{print $2}')" \
  | sha256sum
```

Paste the hex value into `source_sha256:` in `METADATA.yml`.

## Commit and push

```bash
cd ../mydbops-pg-packaging
git add packages/postgresql-14/
git commit -m "postgresql-14: upgrade to 14.22"
git push origin pg14
```

## Tag to trigger the pipeline

```bash
# Format: pg{major}/{package-short-name}-{version}-{revision}
git tag pg14/postgresql-14-14.22-1
git push origin pg14/postgresql-14-14.22-1
```

This triggers the `mydbops-pkg-pg14` CodePipeline via EventBridge.

### RC builds (staging only, skips approval)

Add `-rc1` (or `-rc2`, etc.) suffix to skip the manual approval stage:

```bash
git tag pg14/postgresql-14-14.22-1-rc1
git push origin pg14/postgresql-14-14.22-1-rc1
```

## Watch the pipeline

1. Open AWS Console → CodePipeline → `mydbops-pkg-pg14`
2. The pipeline stages: Source → ParseTag → Build (4 parallel) → Test → Update Staging → Approve → Promote

Build logs are in CloudWatch Logs under the CodeBuild project log group.

## Approval checklist

Before clicking Approve in the pipeline:

- [ ] All 4 Build jobs green
- [ ] Test stage passed (packages installed correctly in containers)
- [ ] Staging APT/YUM repo metadata updated
- [ ] Tested installation from staging repo on a real instance
- [ ] SHA256 sidecar files present in S3 staging path
- [ ] GPG signatures valid

## After promotion

After the Promote stage completes:
- Packages are available in the production APT/YUM repositories
- S3 path: `s3://{bucket}/production/packages/{name}/{version}/`
- The promotion is a copy from staging — the same binaries, not a rebuild
