#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# scripts/new-pg-version.sh — Create a new pgN branch from an existing one
#
# Usage:
#   new-pg-version.sh --new-major 18 --new-version 18.0 --source-major 17 \
#                     --packages-dir ../pg-packaging \
#                     --eol-date 2030-11-12
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

# ─── Args ─────────────────────────────────────────────────────────────────────

NEW_MAJOR=""
NEW_VERSION=""
SOURCE_MAJOR=""
PACKAGES_DIR=""
EOL_DATE=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --new-major)    NEW_MAJOR="$2";    shift 2 ;;
        --new-version)  NEW_VERSION="$2";  shift 2 ;;
        --source-major) SOURCE_MAJOR="$2"; shift 2 ;;
        --packages-dir) PACKAGES_DIR="$2"; shift 2 ;;
        --eol-date)     EOL_DATE="$2";     shift 2 ;;
        *) log_error "Unknown argument: $1"; exit 1 ;;
    esac
done

if [[ -z "$NEW_MAJOR" || -z "$NEW_VERSION" || -z "$SOURCE_MAJOR" || -z "$PACKAGES_DIR" ]]; then
    log_error "--new-major, --new-version, --source-major, and --packages-dir are required"
    exit 1
fi

PACKAGES_DIR="$(cd "$PACKAGES_DIR" && pwd)"
NEW_BRANCH="pg${NEW_MAJOR}"
SOURCE_BRANCH="pg${SOURCE_MAJOR}"

# ─── Create branch ────────────────────────────────────────────────────────────

log_step "Creating ${NEW_BRANCH} from ${SOURCE_BRANCH}"

(
    cd "$PACKAGES_DIR"

    if git rev-parse --verify "$NEW_BRANCH" &>/dev/null; then
        log_error "Branch already exists: $NEW_BRANCH"
        exit 1
    fi

    git checkout "$SOURCE_BRANCH"
    git checkout -b "$NEW_BRANCH"
)

# ─── Rename references ────────────────────────────────────────────────────────

log_step "Renaming postgresql-${SOURCE_MAJOR} → postgresql-${NEW_MAJOR} in all files"

# Rename the package directory
if [[ -d "${PACKAGES_DIR}/packages/postgresql-${SOURCE_MAJOR}" ]]; then
    (cd "$PACKAGES_DIR" && git mv \
        "packages/postgresql-${SOURCE_MAJOR}" \
        "packages/postgresql-${NEW_MAJOR}" \
        2>/dev/null || mv \
        "packages/postgresql-${SOURCE_MAJOR}" \
        "packages/postgresql-${NEW_MAJOR}")
fi

# Find and rename spec file
local_spec=$(find "${PACKAGES_DIR}/packages/postgresql-${NEW_MAJOR}/rpm/main" \
    -name "postgresql-${SOURCE_MAJOR}.spec" 2>/dev/null | head -1 || true)
if [[ -n "$local_spec" ]]; then
    new_spec="${local_spec/postgresql-${SOURCE_MAJOR}.spec/postgresql-${NEW_MAJOR}.spec}"
    (cd "$PACKAGES_DIR" && git mv "$local_spec" "$new_spec" 2>/dev/null || mv "$local_spec" "$new_spec") || true
fi

# Bulk text replacement in all package files
log_info "Replacing text references: ${SOURCE_MAJOR} → ${NEW_MAJOR}"
find "${PACKAGES_DIR}/packages/postgresql-${NEW_MAJOR}" \
    -type f \
    ! -path '*/.git/*' \
    ! -name '*.tar.*' \
    ! -name '*.pdf' \
    -print0 | \
xargs -0 -I{} python3 - {} "$SOURCE_MAJOR" "$NEW_MAJOR" "$NEW_VERSION" <<'PYEOF'
import sys, re

filepath     = sys.argv[1]
old_major    = sys.argv[2]
new_major    = sys.argv[3]
new_version  = sys.argv[4]

try:
    with open(filepath, 'r', errors='replace') as f:
        content = f.read()

    original = content

    # Replace postgresql-{old} with postgresql-{new}
    content = content.replace(f'postgresql-{old_major}', f'postgresql-{new_major}')
    # Replace pgmajorversion references
    old_pkg = int(old_major) * 10
    new_pkg = int(new_major) * 10
    content = content.replace(f'%global packageversion {old_pkg}', f'%global packageversion {new_pkg}')
    content = content.replace(f'%global pgpackageversion {old_major}', f'%global pgpackageversion {new_major}')
    content = content.replace(f'%global prevmajorversion {int(old_major)-1}', f'%global prevmajorversion {int(new_major)-1}')

    if content != original:
        with open(filepath, 'w') as f:
            f.write(content)
except Exception:
    pass
PYEOF

# Update PG_VERSION and BRANCH_EOL files
echo "$NEW_MAJOR" > "${PACKAGES_DIR}/PG_VERSION"
if [[ -n "$EOL_DATE" ]]; then
    echo "$EOL_DATE" > "${PACKAGES_DIR}/BRANCH_EOL"
fi

# Update METADATA.yml version
metadata="${PACKAGES_DIR}/packages/postgresql-${NEW_MAJOR}/METADATA.yml"
if [[ -f "$metadata" ]]; then
    python3 - "$metadata" "$NEW_VERSION" "$NEW_MAJOR" <<'PYEOF'
import sys, re

metadata_file = sys.argv[1]
new_version   = sys.argv[2]
new_major     = sys.argv[3]

with open(metadata_file) as f:
    content = f.read()

content = re.sub(r'(version:\s*)["\']?[\d.]+["\']?',
                 lambda m: m.group(1) + '"' + new_version + '"',
                 content, flags=re.MULTILINE)
content = re.sub(r'(pg_major:\s*)\d+',
                 lambda m: m.group(1) + new_major,
                 content, flags=re.MULTILINE)
content = re.sub(r'(source_sha256:\s*).*',
                 lambda m: m.group(1) + '""',
                 content, flags=re.MULTILINE)

with open(metadata_file, 'w') as f:
    f.write(content)
PYEOF
fi

log_success "Branch ${NEW_BRANCH} created"

echo ""
echo "────────────────────────────────────────────────────────────────"
echo "Post-creation checklist:"
echo ""
echo "  1. Update config/pg-versions.yml in pg-platform:"
echo "       Add pg${NEW_MAJOR} entry with eol_date: ${EOL_DATE:-TBD}"
echo ""
echo "  2. Verify patches still apply:"
echo "       Check debian/main/debian/patches/ for forward-compat issues"
echo ""
echo "  3. Update METADATA.yml:"
echo "       source_url:    set to postgresql-${NEW_VERSION}.tar.bz2 URL"
echo "       source_sha256: fill after setting source_url"
echo ""
echo "  4. Test builds before tagging:"
echo "       ./scripts/build-package.sh \\"
echo "         --package postgresql-${NEW_MAJOR} \\"
echo "         --packages-dir ${PACKAGES_DIR} \\"
echo "         --s3-bucket pg-platform-cicd-artifacts-dev \\"
echo "         --env staging --os ubuntu --release 22 --arch amd64"
echo ""
echo "  5. Once tests pass, push the branch and configure pipeline"
echo "────────────────────────────────────────────────────────────────"
