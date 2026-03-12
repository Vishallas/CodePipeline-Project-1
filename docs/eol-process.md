# End-of-Life Process

When a PostgreSQL major version reaches its community End-of-Life date,
follow this process to archive it cleanly.

## EOL dates

| Version | EOL Date   | Status  |
|---------|------------|---------|
| 17      | 2029-11-08 | stable  |
| 16      | 2028-11-09 | stable  |
| 15      | 2027-11-11 | stable  |
| 14      | 2026-11-12 | stable  |

Reference: https://www.postgresql.org/support/versioning/

## Timeline

- **90 days before EOL**: Notify the team, plan final release
- **30 days before EOL**: Pin to the last minor version, freeze changes
- **EOL date**: Run the EOL process

## Running the EOL process

First, do a dry-run to see what will happen:

```bash
cd mydbops-pg-platform

./scripts/eol.sh \
  --pg-major 14 \
  --packages-dir ../mydbops-pg-packaging
```

Review the output. When ready to apply:

```bash
./scripts/eol.sh \
  --pg-major 14 \
  --packages-dir ../mydbops-pg-packaging \
  --confirm
```

The script:
1. Sets `pipeline_enabled: false` for pg14 in `config/pg-versions.yml`
2. Sets `status: eol` for pg14
3. Disables all `build.yml` targets in `mydbops-pg-packaging/pg14`
4. Writes `ARCHIVED.md` to the pg14 branch
5. Creates the `pg14/eol` git tag

## After running eol.sh

### Infrastructure (Terraform)

- Disable or delete the `mydbops-pkg-pg14` CodePipeline
- Review and update IAM policies if they reference pg14 explicitly
- Update any CloudFront/CDN configurations

### S3 retention

Existing packages remain in S3 indefinitely unless explicitly removed.
Consider setting an S3 lifecycle policy on the archived path:

```
s3://{bucket}/*/packages/postgresql-14/
```

Options:
- Move to S3 Glacier after 6 months
- Set an expiration after N years
- Keep indefinitely (for audit/reproducibility)

### APT/YUM repos

The APT/YUM repo metadata for pg14 remains accessible. Clients pointing at
the pg14 repo will continue to work — no packages will be added or updated.

### Communication

- Announce EOL to all users of the pg14 distribution
- Update internal documentation
- Remove pg14 from any "current versions" dashboards

## Reactivating an archived version

To re-enable a version (e.g. emergency security fix after EOL):

1. Manually edit `config/pg-versions.yml`: set `pipeline_enabled: true`
2. Re-enable targets in `build.yml` for affected packages
3. Follow the normal release process
4. Re-archive after the fix is shipped
