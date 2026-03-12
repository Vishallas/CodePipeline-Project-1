#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# scripts/new-package.sh — Scaffold a new package in mydbops-pg-packaging
#
# Usage:
#   new-package.sh --name postgresql-14-pgvector --version 0.7.4 --pg 14 \
#                  --packages-dir ../mydbops-pg-packaging \
#                  [--source-url URL] [--description TEXT] [--force]
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

# ─── Args ─────────────────────────────────────────────────────────────────────

PACKAGE_NAME=""
VERSION=""
PG_MAJOR=""
PACKAGES_DIR=""
SOURCE_URL=""
DESCRIPTION=""
FORCE=0

while [[ $# -gt 0 ]]; do
    case $1 in
        --name)         PACKAGE_NAME="$2"; shift 2 ;;
        --version)      VERSION="$2";      shift 2 ;;
        --pg)           PG_MAJOR="$2";     shift 2 ;;
        --packages-dir) PACKAGES_DIR="$2"; shift 2 ;;
        --source-url)   SOURCE_URL="$2";   shift 2 ;;
        --description)  DESCRIPTION="$2";  shift 2 ;;
        --force)        FORCE=1;           shift ;;
        *) log_error "Unknown argument: $1"; exit 1 ;;
    esac
done

if [[ -z "$PACKAGE_NAME" || -z "$VERSION" || -z "$PG_MAJOR" || -z "$PACKAGES_DIR" ]]; then
    log_error "--name, --version, --pg, and --packages-dir are required"
    exit 1
fi

PACKAGES_DIR="$(cd "$PACKAGES_DIR" && pwd)"
PLATFORM_DIR="$(dirname "$SCRIPT_DIR")"
TEMPLATES_DIR="${PLATFORM_DIR}/templates"

PKG_DIR="${PACKAGES_DIR}/packages/${PACKAGE_NAME}"

if [[ -d "$PKG_DIR" && $FORCE -eq 0 ]]; then
    log_error "Package directory already exists: $PKG_DIR"
    log_error "Use --force to overwrite"
    exit 1
fi

REVISION="1"
AUTHOR_NAME="${GIT_AUTHOR_NAME:-Mydbops}"
AUTHOR_EMAIL="${GIT_AUTHOR_EMAIL:-ops@mydbops.com}"
DATE="$(date -R)"
YEAR="$(date +%Y)"
SHORT_NAME="${PACKAGE_NAME#postgresql-${PG_MAJOR}-}"
CHANGELOG_DATE="$(date '+%a %b %d %Y')"

# ─── Template rendering ───────────────────────────────────────────────────────

# render_template <template_file> <output_file>
render_template() {
    local tpl="$1"
    local out="$2"
    mkdir -p "$(dirname "$out")"
    sed \
        -e "s|{{PACKAGE_NAME}}|${PACKAGE_NAME}|g" \
        -e "s|{{PG_MAJOR}}|${PG_MAJOR}|g" \
        -e "s|{{VERSION}}|${VERSION}|g" \
        -e "s|{{REVISION}}|${REVISION}|g" \
        -e "s|{{SOURCE_URL}}|${SOURCE_URL}|g" \
        -e "s|{{DESCRIPTION}}|${DESCRIPTION}|g" \
        -e "s|{{DATE}}|${DATE}|g" \
        -e "s|{{AUTHOR_NAME}}|${AUTHOR_NAME}|g" \
        -e "s|{{AUTHOR_EMAIL}}|${AUTHOR_EMAIL}|g" \
        -e "s|{{YEAR}}|${YEAR}|g" \
        -e "s|{{SHORT_NAME}}|${SHORT_NAME}|g" \
        -e "s|{{CHANGELOG_DATE}}|${CHANGELOG_DATE}|g" \
        "$tpl" > "$out"
}

log_step "Scaffolding: ${PACKAGE_NAME} v${VERSION} (PG ${PG_MAJOR})"
mkdir -p "$PKG_DIR"

render_template "${TEMPLATES_DIR}/METADATA.yml.tpl"      "${PKG_DIR}/METADATA.yml"
render_template "${TEMPLATES_DIR}/build.yml.tpl"         "${PKG_DIR}/build.yml"
render_template "${TEMPLATES_DIR}/debian/control.tpl"    "${PKG_DIR}/debian/main/debian/control"
render_template "${TEMPLATES_DIR}/debian/rules.tpl"      "${PKG_DIR}/debian/main/debian/rules"
render_template "${TEMPLATES_DIR}/debian/changelog.tpl"  "${PKG_DIR}/debian/main/debian/changelog"
render_template "${TEMPLATES_DIR}/debian/copyright.tpl"  "${PKG_DIR}/debian/main/debian/copyright"
render_template "${TEMPLATES_DIR}/rpm/package.spec.tpl"  "${PKG_DIR}/rpm/main/${PACKAGE_NAME}.spec"
chmod +x "${PKG_DIR}/debian/main/debian/rules"

# Create debian/source/format
mkdir -p "${PKG_DIR}/debian/main/debian/source"
echo "3.0 (quilt)" > "${PKG_DIR}/debian/main/debian/source/format"

# Create placeholder tests/sql
mkdir -p "${PKG_DIR}/tests/sql"
cat > "${PKG_DIR}/tests/sql/00_version_check.sql" <<SQL
-- Version check for ${PACKAGE_NAME}
SELECT version();
SQL

log_success "Scaffolded: ${PKG_DIR}"

echo ""
echo "────────────────────────────────────────────────────────────────"
echo "Next steps:"
echo ""
echo "  1. Fill in METADATA.yml:"
echo "       source_url:    download URL for the source tarball"
echo "       source_sha256: run: curl -sL <url> | sha256sum"
echo "       description:   one-line package description"
echo ""
echo "  2. Update debian/main/debian/control:"
echo "       Add build dependencies (Build-Depends:)"
echo ""
echo "  3. Update debian/main/debian/rules:"
echo "       Add configure flags and dh overrides"
echo ""
echo "  4. Update rpm/main/${PACKAGE_NAME}.spec:"
echo "       Fill in %build, %install, %files sections"
echo ""
echo "  5. Enable build targets in build.yml:"
echo "       Set 'enabled: true' for targets you want to test"
echo ""
echo "  6. Validate:"
echo "       ./scripts/lint.sh --package ${PACKAGE_NAME} --packages-dir ${PACKAGES_DIR}"
echo ""
echo "  7. Test one target:"
echo "       ./scripts/build-package.sh \\"
echo "         --package ${PACKAGE_NAME} \\"
echo "         --packages-dir ${PACKAGES_DIR} \\"
echo "         --s3-bucket mydbops-cicd-artifacts-dev \\"
echo "         --env staging \\"
echo "         --os ubuntu --release 22 --arch amd64"
echo ""
echo "  8. Once builds pass: enable more targets, PR, tag"
echo "────────────────────────────────────────────────────────────────"
