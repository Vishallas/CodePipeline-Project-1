#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# scripts/bump-version.sh — Safe version bump with full audit trail
#
# Updates METADATA.yml, debian/changelog, and RPM spec.
# Does NOT commit — operator reviews diff and commits manually.
#
# Usage:
#   bump-version.sh --package NAME --version X.Y.Z \
#                   --packages-dir DIR \
#                   [--revision N] [--change "message"] [--no-git]
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

# ─── Args ─────────────────────────────────────────────────────────────────────

PACKAGE_NAME=""
NEW_VERSION=""
NEW_REVISION="1"
CHANGE_MSG=""
PACKAGES_DIR=""
NO_GIT=0

while [[ $# -gt 0 ]]; do
    case $1 in
        --package)      PACKAGE_NAME="$2"; shift 2 ;;
        --version)      NEW_VERSION="$2";  shift 2 ;;
        --revision)     NEW_REVISION="$2"; shift 2 ;;
        --change)       CHANGE_MSG="$2";   shift 2 ;;
        --packages-dir) PACKAGES_DIR="$2"; shift 2 ;;
        --no-git)       NO_GIT=1;          shift ;;
        *) log_error "Unknown argument: $1"; exit 1 ;;
    esac
done

if [[ -z "$PACKAGE_NAME" || -z "$NEW_VERSION" || -z "$PACKAGES_DIR" ]]; then
    log_error "--package, --version, and --packages-dir are required"
    exit 1
fi

PACKAGES_DIR="$(cd "$PACKAGES_DIR" && pwd)"
PKG_DIR="${PACKAGES_DIR}/packages/${PACKAGE_NAME}"
METADATA="${PKG_DIR}/METADATA.yml"
CHANGELOG="${PKG_DIR}/debian/main/debian/changelog"
SPEC_FILE=$(find "${PKG_DIR}/rpm/main" -name '*.spec' 2>/dev/null | head -1 || true)

if [[ ! -f "$METADATA" ]]; then
    log_error "METADATA.yml not found: $METADATA"
    exit 1
fi

CHANGE_MSG="${CHANGE_MSG:-Upgrade to ${PACKAGE_NAME} ${NEW_VERSION}}"
AUTHOR_NAME="${GIT_AUTHOR_NAME:-Pg-platform}"
AUTHOR_EMAIL="${GIT_AUTHOR_EMAIL:-ops@pg-platform.com}"
DATE_RFC="$(date -R)"
DATE_RPM="$(date '+%a %b %d %Y')"

log_step "Bumping ${PACKAGE_NAME} to ${NEW_VERSION}-${NEW_REVISION}"

# ── METADATA.yml ──────────────────────────────────────────────────────────────

log_info "Updating METADATA.yml"
python3 - "$METADATA" "$NEW_VERSION" "$NEW_REVISION" <<'PYEOF'
import sys, re

metadata_file = sys.argv[1]
new_version   = sys.argv[2]
new_revision  = sys.argv[3]

with open(metadata_file) as f:
    content = f.read()

# Update version
content = re.sub(r'(^\s*version:\s*)["\']?[\d.]+["\']?',
                 lambda m: m.group(1) + '"' + new_version + '"',
                 content, flags=re.MULTILINE)
# Update revision
content = re.sub(r'(^\s*revision:\s*)\d+',
                 lambda m: m.group(1) + new_revision,
                 content, flags=re.MULTILINE)
# Clear source_sha256 (must be refilled after version bump)
content = re.sub(r'(^\s*source_sha256:\s*).*',
                 lambda m: m.group(1) + '""',
                 content, flags=re.MULTILINE)

with open(metadata_file, 'w') as f:
    f.write(content)
print("METADATA.yml updated")
PYEOF

# ── debian/changelog ──────────────────────────────────────────────────────────

if [[ -f "$CHANGELOG" ]]; then
    log_info "Prepending debian/changelog entry"
    local_tmp=$(mktemp)
    cat > "$local_tmp" <<CLENTRY
${PACKAGE_NAME} (${NEW_VERSION}-${NEW_REVISION}) unstable; urgency=medium

  * ${CHANGE_MSG}

 -- ${AUTHOR_NAME} <${AUTHOR_EMAIL}>  ${DATE_RFC}

CLENTRY
    cat "$CHANGELOG" >> "$local_tmp"
    mv "$local_tmp" "$CHANGELOG"
fi

# ── RPM spec ──────────────────────────────────────────────────────────────────

if [[ -n "$SPEC_FILE" && -f "$SPEC_FILE" ]]; then
    log_info "Updating RPM spec: $(basename "$SPEC_FILE")"
    python3 - "$SPEC_FILE" "$NEW_VERSION" "$NEW_REVISION" "$DATE_RPM" \
              "$AUTHOR_NAME" "$AUTHOR_EMAIL" "$CHANGE_MSG" <<'PYEOF'
import sys, re

spec_file   = sys.argv[1]
new_version = sys.argv[2]
new_revision = sys.argv[3]
date_rpm    = sys.argv[4]
author_name = sys.argv[5]
author_email = sys.argv[6]
change_msg  = sys.argv[7]

with open(spec_file) as f:
    content = f.read()

# Update Version:
content = re.sub(r'^(Version:\s*)[\d.]+',
                 lambda m: m.group(1) + new_version,
                 content, flags=re.MULTILINE)

# Update Release: (reset to new_revision + keep dist tag)
content = re.sub(r'^(Release:\s*)\S+',
                 lambda m: m.group(1) + new_revision + 'PGDG%{?dist}',
                 content, flags=re.MULTILINE)

# Prepend %changelog entry
changelog_entry = (
    f"* {date_rpm} {author_name} <{author_email}> - {new_version}-{new_revision}\n"
    f"- {change_msg}\n\n"
)
content = content.replace('%changelog\n', '%changelog\n' + changelog_entry, 1)

with open(spec_file, 'w') as f:
    f.write(content)
print("RPM spec updated")
PYEOF
fi

# ── Show diff ─────────────────────────────────────────────────────────────────

echo ""
log_success "Version bumped to ${NEW_VERSION}-${NEW_REVISION}"
echo ""
log_info "Review the diff before committing:"
if [[ $NO_GIT -eq 0 ]] && command -v git &>/dev/null; then
    (cd "$PACKAGES_DIR" && git diff 2>/dev/null) || true
fi
echo ""
log_warn "IMPORTANT: Update source_sha256 in METADATA.yml:"
log_warn "  curl -sL \$(yaml_get METADATA.yml package.source_url) | sha256sum"
