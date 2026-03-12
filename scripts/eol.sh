#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# scripts/eol.sh — Archive and retire an EOL PostgreSQL major version
#
# Without --confirm: dry-run only (prints what would be done).
# With --confirm: makes changes.
#
# Usage:
#   eol.sh --pg-major 14 --packages-dir ../mydbops-pg-packaging [--confirm]
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

# ─── Args ─────────────────────────────────────────────────────────────────────

PG_MAJOR=""
PACKAGES_DIR=""
CONFIRM=0

while [[ $# -gt 0 ]]; do
    case $1 in
        --pg-major)     PG_MAJOR="$2";     shift 2 ;;
        --packages-dir) PACKAGES_DIR="$2"; shift 2 ;;
        --confirm)      CONFIRM=1;         shift ;;
        *) log_error "Unknown argument: $1"; exit 1 ;;
    esac
done

if [[ -z "$PG_MAJOR" || -z "$PACKAGES_DIR" ]]; then
    log_error "--pg-major and --packages-dir are required"
    exit 1
fi

PACKAGES_DIR="$(cd "$PACKAGES_DIR" && pwd)"
PLATFORM_DIR="$(dirname "$SCRIPT_DIR")"
PG_VERSIONS_YML="${PLATFORM_DIR}/config/pg-versions.yml"

if [[ $CONFIRM -eq 0 ]]; then
    log_warn "DRY-RUN MODE — pass --confirm to apply changes"
    echo ""
fi

log_step "EOL process for PostgreSQL ${PG_MAJOR}"

# ── Step 1: Disable pipeline in config/pg-versions.yml ────────────────────────

echo "  [1] Would set pipeline_enabled: false for pg${PG_MAJOR} in config/pg-versions.yml"
if [[ $CONFIRM -eq 1 ]]; then
    python3 - "$PG_VERSIONS_YML" "$PG_MAJOR" <<'PYEOF'
import sys, yaml

ymlfile  = sys.argv[1]
pg_major = int(sys.argv[2])

with open(ymlfile) as f:
    content = f.read()

# Simple text-based replacement to preserve formatting
import re
# Find the block for this pg_major and set pipeline_enabled: false
lines = content.split('\n')
in_block = False
result = []
for line in lines:
    if re.match(r'\s*-\s*major:\s*' + str(pg_major) + r'\s*$', line):
        in_block = True
    elif in_block and re.match(r'\s*-\s*major:', line):
        in_block = False
    if in_block and 'pipeline_enabled:' in line:
        line = re.sub(r'pipeline_enabled:\s*(true|false)', 'pipeline_enabled: false', line)
    if in_block and 'status:' in line:
        line = re.sub(r'status:\s*\w+', 'status: eol', line)
    result.append(line)

with open(ymlfile, 'w') as f:
    f.write('\n'.join(result))
print(f"pg-versions.yml: pg{pg_major} pipeline_enabled=false, status=eol")
PYEOF
    log_success "config/pg-versions.yml updated"
fi

# ── Step 2: Disable all build.yml targets in packaging repo ───────────────────

echo "  [2] Would disable all build.yml targets for packages in pg${PG_MAJOR} branch"
BUILD_YML_LIST=$(find "${PACKAGES_DIR}/packages" -name 'build.yml' 2>/dev/null || true)
if [[ $CONFIRM -eq 1 ]]; then
    while IFS= read -r build_yml; do
        python3 - "$build_yml" <<'PYEOF'
import sys, re

with open(sys.argv[1]) as f:
    content = f.read()

content = re.sub(r'enabled:\s*true', 'enabled: false', content)

with open(sys.argv[1], 'w') as f:
    f.write(content)
PYEOF
        log_info "Disabled targets in: $build_yml"
    done <<< "$BUILD_YML_LIST"
    log_success "All build.yml targets disabled"
fi

# ── Step 3: Write ARCHIVED.md to packaging branch ─────────────────────────────

ARCHIVED_MSG="# ARCHIVED

PostgreSQL ${PG_MAJOR} reached End of Life on $(date +%Y-%m-%d).

This branch is archived. No new builds will be triggered.
The pipeline has been disabled in config/pg-versions.yml.
Existing packages remain available in S3 and the APT/YUM repositories.

See: https://www.postgresql.org/support/versioning/
"
echo "  [3] Would write ARCHIVED.md to ${PACKAGES_DIR}"
if [[ $CONFIRM -eq 1 ]]; then
    echo "$ARCHIVED_MSG" > "${PACKAGES_DIR}/ARCHIVED.md"
    log_success "ARCHIVED.md written"
fi

# ── Step 4: Create EOL git tag ────────────────────────────────────────────────

EOL_TAG="pg${PG_MAJOR}/eol"
echo "  [4] Would create git tag: ${EOL_TAG}"
if [[ $CONFIRM -eq 1 ]]; then
    (
        cd "$PACKAGES_DIR"
        git add -A 2>/dev/null || true
        git commit -m "Archive pg${PG_MAJOR}: EOL $(date +%Y-%m-%d)" 2>/dev/null || true
        git tag "$EOL_TAG" 2>/dev/null || log_warn "Tag ${EOL_TAG} already exists"
    ) || log_warn "Git operations failed — manual commit/tag required"
    log_success "EOL tag created: ${EOL_TAG}"
fi

echo ""
if [[ $CONFIRM -eq 0 ]]; then
    log_warn "Dry-run complete. Run with --confirm to apply."
else
    log_success "EOL process complete for PostgreSQL ${PG_MAJOR}"
fi

echo ""
echo "────────────────────────────────────────────────────────────────"
echo "Reminder: Update Terraform/infrastructure:"
echo "  - Disable or delete the CodePipeline for pg${PG_MAJOR}"
echo "  - Review S3 lifecycle/retention policies for archived packages"
echo "  - Update CloudFront/CDN if needed"
echo "────────────────────────────────────────────────────────────────"
