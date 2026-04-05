# Branch Strategy

## Two-repo model

| Repo | Purpose | Branches |
|------|---------|---------|
| `pg-platform` | Build infrastructure, scripts, buildspecs | `main` only |
| `pg-packaging` | Package definitions | `pg14`, `pg15`, `pg16`, `pg17`, `tools` |

## One branch per PG major

Each `pgN` branch in `pg-packaging` contains package definitions for
that PostgreSQL major version. All packages on a branch are built against the
same PG major version.

```
pg17/   ← postgresql-17, postgresql-17-pgvector, etc.
pg16/   ← postgresql-16, postgresql-16-pgvector, etc.
pg15/   ← ...
pg14/   ← ...
tools/  ← pgbouncer, pgbackrest, barman, etc. (PG-version-agnostic)
```

## Backporting fixes

Use `backport.sh` to cherry-pick a commit from one branch to another:

```bash
cd pg-platform

# Backport a bug fix from pg17 to pg16 and pg15
./scripts/backport.sh \
  --from pg17 \
  --to pg16 pg15 \
  --commit abc1234 \
  --packages-dir ../pg-packaging
```

If there are conflicts, the script stops and prints instructions for manual resolution.

### Dry-run mode

```bash
./scripts/backport.sh \
  --from pg17 \
  --to pg16 pg15 \
  --commit abc1234 \
  --packages-dir ../pg-packaging \
  --dry-run
```

Dry-run uses `--no-commit` to preview without actually committing. It aborts
and resets the index on conflict.

## Adding a new PG major version

When PostgreSQL releases a new major version (e.g. 18):

```bash
cd pg-platform

./scripts/new-pg-version.sh \
  --new-major 18 \
  --new-version 18.0 \
  --source-major 17 \
  --eol-date 2030-11-12 \
  --packages-dir ../pg-packaging
```

Then follow the printed checklist:
1. Update `config/pg-versions.yml` to add the pg18 entry
2. Verify patches still apply
3. Set `source_url` and `source_sha256` in `METADATA.yml`
4. Test builds before tagging

## The `tools` branch

PG-version-agnostic tools (pgbouncer, pgbackrest, barman, etc.) live on the
`tools` branch. They use the same `METADATA.yml` + `build.yml` format.

Tag format for tools:
```
tools/pgbouncer-1.22.0-1
tools/pgbackrest-2.50.0-1
```

## Platform repo (main only)

`pg-platform` has a single `main` branch. All script and buildspec
changes go here. Changes take effect on the next pipeline run — there is no
need to update packaging branches when platform scripts are updated.
