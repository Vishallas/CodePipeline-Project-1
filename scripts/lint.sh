#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# scripts/lint.sh — Validate package definitions in pg-packaging
#
# Usage:
#   lint.sh --package NAME --packages-dir DIR [--strict]
#   lint.sh --all --packages-dir DIR [--strict]
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

# ─── Args ─────────────────────────────────────────────────────────────────────

PACKAGE_NAME=""
PACKAGES_DIR=""
LINT_ALL=0
STRICT=0

while [[ $# -gt 0 ]]; do
    case $1 in
        --package)      PACKAGE_NAME="$2"; shift 2 ;;
        --packages-dir) PACKAGES_DIR="$2"; shift 2 ;;
        --all)          LINT_ALL=1;        shift ;;
        --strict)       STRICT=1;          shift ;;
        *) log_error "Unknown argument: $1"; exit 1 ;;
    esac
done

if [[ $LINT_ALL -eq 0 && -z "$PACKAGE_NAME" ]]; then
    log_error "Either --package NAME or --all is required"
    exit 1
fi
if [[ -z "$PACKAGES_DIR" ]]; then
    log_error "--packages-dir is required"
    exit 1
fi

PACKAGES_DIR="$(cd "$PACKAGES_DIR" && pwd)"

# ─── Result tracking ──────────────────────────────────────────────────────────

TOTAL_FAIL=0
TOTAL_WARN=0

pass() { echo -e "  ${GREEN}[PASS]${NC} $*"; }
warn() { echo -e "  ${YELLOW}[WARN]${NC} $*" >&2; TOTAL_WARN=$((TOTAL_WARN+1)); }
fail() { echo -e "  ${RED}[FAIL]${NC} $*" >&2; TOTAL_FAIL=$((TOTAL_FAIL+1)); }

# ─── Per-package lint ─────────────────────────────────────────────────────────

lint_package() {
    local pkg_name="$1"
    local pkg_dir="${PACKAGES_DIR}/packages/${pkg_name}"

    log_step "Linting: ${pkg_name}"

    local metadata="${pkg_dir}/METADATA.yml"
    local build_yml="${pkg_dir}/build.yml"

    # ── METADATA.yml ──────────────────────────────────────────────────────────
    if [[ ! -f "$metadata" ]]; then
        fail "METADATA.yml missing: $metadata"
        return
    fi
    pass "METADATA.yml exists"

    local md_name md_version md_revision md_pg_major md_source_url md_source_sha256
    md_name=$(yaml_get "$metadata" 'package.name' 2>/dev/null || true)
    md_version=$(yaml_get "$metadata" 'package.version' 2>/dev/null || true)
    md_revision=$(yaml_get "$metadata" 'package.revision' 2>/dev/null || true)
    md_pg_major=$(yaml_get "$metadata" 'package.pg_major' 2>/dev/null || true)
    md_source_url=$(yaml_get "$metadata" 'package.source_url' 2>/dev/null || true)
    md_source_sha256=$(yaml_get "$metadata" 'package.source_sha256' 2>/dev/null || true)

    [[ -n "$md_name" && "$md_name" != "null" ]]    && pass "METADATA.yml: package.name = '$md_name'"    || fail "METADATA.yml: package.name is missing"
    [[ -n "$md_version" && "$md_version" != "null" ]] && pass "METADATA.yml: package.version = '$md_version'" || fail "METADATA.yml: package.version is missing"
    [[ -n "$md_revision" && "$md_revision" != "null" ]] && pass "METADATA.yml: package.revision = '$md_revision'" || fail "METADATA.yml: package.revision is missing"
    [[ -n "$md_source_url" && "$md_source_url" != "null" ]] && pass "METADATA.yml: package.source_url is set" || fail "METADATA.yml: package.source_url is missing"
    [[ -z "$md_source_sha256" || "$md_source_sha256" == "null" || "$md_source_sha256" == '""' || "$md_source_sha256" == "" ]] && \
        warn "METADATA.yml: package.source_sha256 is empty (set after initial scaffold)" || \
        pass "METADATA.yml: package.source_sha256 is set"

    # Cross-check: package dir name vs METADATA name
    if [[ -n "$md_name" && "$md_name" != "$pkg_name" ]]; then
        fail "Package dir name '${pkg_name}' != METADATA.yml package.name '${md_name}'"
    else
        pass "Package dir name matches METADATA.yml name"
    fi

    # Cross-check: pg_major in package name vs METADATA pg_major
    if [[ -n "$md_pg_major" && "$md_pg_major" != "null" ]]; then
        if echo "$pkg_name" | grep -q "\-${md_pg_major}"; then
            pass "METADATA.yml: pg_major (${md_pg_major}) matches package name"
        else
            warn "METADATA.yml: pg_major (${md_pg_major}) not found in package name '${pkg_name}'"
        fi
    fi

    # ── build.yml ─────────────────────────────────────────────────────────────
    if [[ ! -f "$build_yml" ]]; then
        fail "build.yml missing: $build_yml"
    else
        pass "build.yml exists"
        # Check it has a targets key and at least one entry
        local target_count
        target_count=$(python3 - "$build_yml" <<'PYEOF' 2>/dev/null || echo "0"
import sys, yaml
with open(sys.argv[1]) as f: data = yaml.safe_load(f)
print(len(data.get('targets', [])))
PYEOF
        )
        if [[ "$target_count" -gt 0 ]]; then
            pass "build.yml: ${target_count} target(s) defined"
        else
            fail "build.yml: no targets defined"
        fi
    fi

    # ── Debian packaging ──────────────────────────────────────────────────────
    local debian_main="${pkg_dir}/debian/main/debian"
    if [[ -d "$debian_main" ]]; then
        pass "debian/main/debian/ exists"

        local control="${debian_main}/control"
        local rules="${debian_main}/rules"
        local changelog="${debian_main}/changelog"

        if [[ -f "$control" ]]; then
            pass "debian/control exists"
            # Verify Source: matches package name
            local deb_source
            deb_source=$(grep "^Source:" "$control" | awk '{print $2}' | tr -d '[:space:]')
            if [[ "$deb_source" == "$pkg_name" ]]; then
                pass "debian/control: Source = ${deb_source}"
            else
                warn "debian/control: Source '${deb_source}' != package name '${pkg_name}'"
            fi
        else
            fail "debian/control missing"
        fi

        if [[ -f "$rules" ]]; then
            pass "debian/rules exists"
        else
            fail "debian/rules missing"
        fi

        if [[ -f "$changelog" ]]; then
            pass "debian/changelog exists"
            # Check changelog version matches METADATA version
            local cl_version
            cl_version=$(head -1 "$changelog" | grep -oP '\(\K[^)]+' | cut -d- -f1 || true)
            if [[ -n "$cl_version" && -n "$md_version" && "$cl_version" == "$md_version" ]]; then
                pass "debian/changelog: version ${cl_version} matches METADATA version"
            elif [[ -n "$cl_version" && -n "$md_version" ]]; then
                warn "debian/changelog: version '${cl_version}' != METADATA version '${md_version}'"
            fi
        else
            fail "debian/changelog missing"
        fi
    else
        warn "debian/main/debian/ not found (may be intentional for RPM-only packages)"
    fi

    # ── RPM spec ──────────────────────────────────────────────────────────────
    local rpm_main="${pkg_dir}/rpm/main"
    if [[ -d "$rpm_main" ]]; then
        local spec_file
        spec_file=$(find "$rpm_main" -maxdepth 1 -name '*.spec' | head -1)
        if [[ -n "$spec_file" ]]; then
            pass "rpm spec exists: $(basename "$spec_file")"
            # Check spec Version matches METADATA
            local spec_version
            spec_version=$(grep "^Version:" "$spec_file" | awk '{print $2}' | tr -d '[:space:]' || true)
            if [[ -n "$spec_version" && -n "$md_version" && "$spec_version" == "$md_version" ]]; then
                pass "rpm spec: Version ${spec_version} matches METADATA version"
            elif [[ -n "$spec_version" && -n "$md_version" ]]; then
                warn "rpm spec: Version '${spec_version}' != METADATA version '${md_version}'"
            fi
            # Check %changelog exists
            if grep -q "^%changelog" "$spec_file"; then
                pass "rpm spec: %changelog section present"
            else
                warn "rpm spec: %changelog section missing"
            fi
        else
            warn "rpm/main/ exists but no .spec file found"
        fi
    else
        warn "rpm/main/ not found (may be intentional for DEB-only packages)"
    fi
}

# ─── Main ─────────────────────────────────────────────────────────────────────

if [[ $LINT_ALL -eq 1 ]]; then
    for metadata_file in "${PACKAGES_DIR}"/packages/*/METADATA.yml; do
        pkg_dir=$(dirname "$metadata_file")
        pkg=$(basename "$pkg_dir")
        lint_package "$pkg"
        echo ""
    done
else
    lint_package "$PACKAGE_NAME"
fi

echo ""
echo "─────────────────────────────────────"
echo "Lint summary: FAIL=${TOTAL_FAIL}  WARN=${TOTAL_WARN}"

if [[ $TOTAL_FAIL -gt 0 ]]; then
    log_error "Lint FAILED: ${TOTAL_FAIL} error(s)"
    exit 1
fi

if [[ $STRICT -eq 1 && $TOTAL_WARN -gt 0 ]]; then
    log_error "Lint FAILED (strict mode): ${TOTAL_WARN} warning(s)"
    exit 1
fi

log_success "Lint passed"
