#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# direct.sh — Direct (local) build environment driver
# ─────────────────────────────────────────────────────────────────────────────
#
# Builds packages directly on the host machine without any isolation.
# This is the simplest build method but does not guarantee a clean
# environment. Useful for quick local testing and development.
#
# For RPMs: requires rpm-build, spectool (rpmdevtools)
# For DEBs: requires dpkg-dev, debhelper
#
# WARNING: This builder modifies the host system's rpmbuild tree. Use
# Docker or Mock for reproducible production builds.
#
# ─────────────────────────────────────────────────────────────────────────────

DRIVER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${DRIVER_DIR}/common.sh"

# ─── Configuration ─────────────────────────────────────────────────────────

# RPM build root (defaults to ~/rpmbuild)
DIRECT_RPM_TOPDIR="${DIRECT_RPM_TOPDIR:-${HOME}/rpmbuild}"

# ─── Dependency Check ──────────────────────────────────────────────────────

builder_direct_check_deps() {
    local has_rpm=false has_deb=false

    if command -v rpmbuild &>/dev/null; then
        has_rpm=true
    fi
    if command -v dpkg-buildpackage &>/dev/null; then
        has_deb=true
    fi

    if ! $has_rpm && ! $has_deb; then
        log_error "No build tools found. Install one of:"
        log_error "  RPM: sudo dnf install rpm-build rpmdevtools"
        log_error "  DEB: sudo apt install dpkg-dev debhelper"
        return 1
    fi

    if $has_rpm; then
        log_success "Direct RPM build ready (rpmbuild available)"
    fi
    if $has_deb; then
        log_success "Direct DEB build ready (dpkg-buildpackage available)"
    fi

    return 0
}

# ─── Build RPM ─────────────────────────────────────────────────────────────

# Build an RPM package directly on the host.
# Usage: builder_direct_build_rpm <package> <distro> <pg_major> <pg_full> <pg_release> [output_base]
builder_direct_build_rpm() {
    local package="$1"
    local distro="$2"
    local pg_major="$3"
    local pg_full="$4"
    local pg_release="$5"
    local output_base="${6:-${BUILDENV_PROJECT_ROOT}/output}"

    require_command rpmbuild "rpmbuild (sudo dnf install rpm-build)" || return 1

    local build_dir
    build_dir=$(init_build_output "direct" "$distro" "$package" "$output_base")
    local log_file
    log_file=$(get_build_log "direct" "$distro" "$package" "$output_base")

    # Find spec file
    local spec_file="" pkg_dir=""
    for search_dir in \
        "${BUILDENV_PROJECT_ROOT}/rpm/redhat/main/non-common/${package}/${distro}" \
        "${BUILDENV_PROJECT_ROOT}/rpm/redhat/main/non-common/${package}/main" \
        "${BUILDENV_PROJECT_ROOT}/rpm/redhat/main/common/${package}/${distro}" \
        "${BUILDENV_PROJECT_ROOT}/rpm/redhat/main/common/${package}/main" \
        "${BUILDENV_PROJECT_ROOT}/rpm/redhat/main/extras/${package}/${distro}" \
        "${BUILDENV_PROJECT_ROOT}/rpm/redhat/main/extras/${package}/main"; do
        if [[ -d "$search_dir" ]]; then
            spec_file=$(find "$search_dir" -maxdepth 1 -name '*.spec' -print -quit 2>/dev/null)
            if [[ -n "$spec_file" ]]; then
                pkg_dir="$search_dir"
                break
            fi
        fi
    done

    if [[ -z "$spec_file" ]]; then
        log_error "No spec file found for package: ${package}"
        return 1
    fi

    # Set up rpmbuild directory tree
    local topdir="${DIRECT_RPM_TOPDIR}/pg${pg_major}"
    mkdir -p "${topdir}"/{BUILD,BUILDROOT,RPMS,SRPMS,SOURCES,SPECS}

    log_build "[direct] ${package} (PG${pg_major} ${pg_full}-${pg_release}) -> ${distro}"
    log_info "Spec:    ${spec_file}"
    log_info "TopDir:  ${topdir}"
    log_info "Output:  ${build_dir}"
    log_info "Log:     ${log_file}"
    log_warn "Building directly on host — no isolation!"

    (
        cd "$pkg_dir"

        # Download sources
        log_step "Downloading sources..."
        if command -v spectool &>/dev/null; then
            spectool -g -S \
                --define "pgmajorversion ${pg_major}" \
                --define "pginstdir /usr/pgsql-${pg_major}" \
                --define "pgpackageversion ${pg_major}" \
                "$spec_file" 2>&1 || true
        fi

        # Build RPMs
        log_step "Building RPMs..."
        rpmbuild \
            --define "_topdir ${topdir}" \
            --define "_sourcedir $(pwd)" \
            --define "_specdir $(pwd)" \
            --define "_builddir ${topdir}/BUILD" \
            --define "_buildrootdir ${topdir}/BUILDROOT" \
            --define "_srcrpmdir ${topdir}/SRPMS" \
            --define "_rpmdir ${topdir}/RPMS" \
            --define "pgmajorversion ${pg_major}" \
            --define "pginstdir /usr/pgsql-${pg_major}" \
            --define "pgpackageversion ${pg_major}" \
            -bb "$spec_file" 2>&1

        local build_rc=$?

        # Build SRPM
        log_step "Building SRPM..."
        rpmbuild \
            --define "_topdir ${topdir}" \
            --define "_sourcedir $(pwd)" \
            --define "_specdir $(pwd)" \
            --define "_builddir ${topdir}/BUILD" \
            --define "_buildrootdir ${topdir}/BUILDROOT" \
            --define "_srcrpmdir ${topdir}/SRPMS" \
            --define "_rpmdir ${topdir}/RPMS" \
            --define "pgmajorversion ${pg_major}" \
            --define "pginstdir /usr/pgsql-${pg_major}" \
            --define "pgpackageversion ${pg_major}" \
            --nodeps -bs "$spec_file" 2>&1 || true

        # Collect artifacts
        log_step "Collecting artifacts..."
        for rpm_file in "${topdir}"/RPMS/*/*.rpm "${topdir}"/RPMS/*.rpm; do
            [[ -f "$rpm_file" ]] || continue
            local arch
            arch=$(rpm -qp --queryformat '%{ARCH}' "$rpm_file" 2>/dev/null || echo "x86_64")
            mkdir -p "${build_dir}/RPMS/${arch}"
            cp -v "$rpm_file" "${build_dir}/RPMS/${arch}/"
        done

        for srpm_file in "${topdir}"/SRPMS/*.src.rpm; do
            [[ -f "$srpm_file" ]] || continue
            cp -v "$srpm_file" "${build_dir}/SRPMS/"
        done

        exit $build_rc

    ) 2>&1 | tee "${log_file}"

    local rc=${PIPESTATUS[0]}

    if [[ $rc -eq 0 ]]; then
        log_success "[direct] ${package} for ${distro} completed"
        organize_rpm_output "${build_dir}" "${distro}" "${output_base}"
        summarize_build_output "${build_dir}"
    else
        log_error "[direct] ${package} for ${distro} FAILED (see ${log_file})"
    fi

    return $rc
}

# ─── Build DEB ─────────────────────────────────────────────────────────────

# Build a DEB package directly on the host.
# Usage: builder_direct_build_deb <package> <dist> <pg_major> <pg_full> <pg_release> [output_base]
builder_direct_build_deb() {
    local package="$1"
    local dist="$2"
    local pg_major="$3"
    local pg_full="$4"
    local pg_release="$5"
    local output_base="${6:-${BUILDENV_PROJECT_ROOT}/output}"

    require_command dpkg-buildpackage "dpkg-dev (sudo apt install dpkg-dev)" || return 1

    local build_dir
    build_dir=$(init_build_output "direct" "$dist" "$package" "$output_base")
    local log_file
    log_file=$(get_build_log "direct" "$dist" "$package" "$output_base")

    log_build "[direct] DEB ${package} (PG${pg_major} ${pg_full}-${pg_release}) -> ${dist}"
    log_info "Output:  ${build_dir}"
    log_info "Log:     ${log_file}"
    log_warn "Building directly on host — no isolation!"

    local work_dir
    work_dir=$(mktemp -d)

    (
        cd "$work_dir"

        # Download source
        log_step "Downloading PostgreSQL ${pg_full} source..."
        wget -q "https://ftp.postgresql.org/pub/source/v${pg_full}/postgresql-${pg_full}.tar.bz2" || {
            log_error "Failed to download source"
            exit 1
        }

        tar -xjf "postgresql-${pg_full}.tar.bz2"
        cd "postgresql-${pg_full}"

        # Generate debian files
        log_step "Preparing debian files..."
        mkdir -p debian

        if [[ -f "${BUILDENV_PROJECT_ROOT}/packaging/debian/control.in" ]]; then
            python3 "${BUILDENV_PROJECT_ROOT}/scripts/generate-control.py" \
                --template "${BUILDENV_PROJECT_ROOT}/packaging/debian/control.in" \
                --output debian/control \
                --major "${pg_major}" 2>/dev/null || true
        fi

        # Create minimal debian files if missing
        if [[ ! -f debian/changelog ]]; then
            cat > debian/changelog << CHLOG
postgresql-${pg_major} (${pg_full}-${pg_release}) ${dist}; urgency=medium

  * Package build via packaging-postgresql build system.

 -- PostgreSQL Packaging <packaging@example.com>  $(date -R)
CHLOG
        fi

        if [[ ! -f debian/rules ]]; then
            cat > debian/rules << 'RULES'
#!/usr/bin/make -f
%:
	dh $@
RULES
            chmod +x debian/rules
        fi

        if [[ ! -f debian/compat ]]; then
            echo "13" > debian/compat
        fi

        # Build
        log_step "Building DEB packages..."
        dpkg-buildpackage -us -uc -b 2>&1

        local build_rc=$?

        # Collect artifacts
        log_step "Collecting artifacts..."
        for deb_file in ../*.deb; do
            [[ -f "$deb_file" ]] || continue
            cp -v "$deb_file" "${build_dir}/DEBS/"
        done

        for meta_file in ../*.changes ../*.buildinfo; do
            [[ -f "$meta_file" ]] || continue
            cp -v "$meta_file" "${build_dir}/DEBS/"
        done

        exit $build_rc

    ) 2>&1 | tee "${log_file}"

    local rc=${PIPESTATUS[0]}

    if [[ $rc -eq 0 ]]; then
        log_success "[direct] DEB ${package} for ${dist} completed"
        organize_deb_output "${build_dir}" "${dist}" "${output_base}"
        summarize_build_output "${build_dir}"
    else
        log_error "[direct] DEB ${package} for ${dist} FAILED (see ${log_file})"
    fi

    rm -rf "$work_dir"
    return $rc
}

# ─── Shell ─────────────────────────────────────────────────────────────────

builder_direct_shell() {
    log_info "[direct] Opening a shell in the current environment..."
    log_info "You are on the host. Build tools should already be in PATH."
    echo ""
    echo "  Useful commands:"
    echo "    rpmbuild --version     # Check RPM build tools"
    echo "    dpkg-buildpackage -h   # Check DEB build tools"
    echo "    spectool -h            # Source download helper"
    echo ""
    exec "${SHELL:-/bin/bash}"
}

# ─── Clean ─────────────────────────────────────────────────────────────────

# Clean direct build artifacts.
# Usage: builder_direct_clean
builder_direct_clean() {
    log_step "[direct] Cleaning rpmbuild tree..."

    if [[ -d "${DIRECT_RPM_TOPDIR}" ]]; then
        for pg_dir in "${DIRECT_RPM_TOPDIR}"/pg*/; do
            [[ -d "$pg_dir" ]] || continue
            rm -rf "${pg_dir:?}/BUILD" "${pg_dir:?}/BUILDROOT"
            log_info "Cleaned: ${pg_dir}"
        done
    fi

    log_success "[direct] Cleanup complete"
}
