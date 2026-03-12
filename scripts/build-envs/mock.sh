#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# mock.sh — Mock build environment driver
# ─────────────────────────────────────────────────────────────────────────────
#
# Builds RPM packages using Mock, a chroot-based RPM build tool.
# Mock creates clean build roots for each build, ensuring reproducible
# results without requiring Docker.
#
# Mock is the standard tool used by Fedora/EPEL/CentOS for building RPMs
# in isolated environments. It uses dnf/yum to install build dependencies
# inside a chroot.
#
# Required tools: mock, rpm-build, spectool (rpmdevtools)
#
# Setup:
#   sudo dnf install mock rpm-build rpmdevtools
#   sudo usermod -a -G mock $(whoami)
#
# ─────────────────────────────────────────────────────────────────────────────

DRIVER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${DRIVER_DIR}/common.sh"

# ─── Configuration ─────────────────────────────────────────────────────────

# Map distro IDs to mock configuration names
_mock_config_for_distro() {
    local distro="$1"
    case "$distro" in
        EL-8)    echo "centos-stream-8-x86_64" ;;
        EL-9)    echo "centos-stream-9-x86_64" ;;
        EL-10)   echo "centos-stream-10-x86_64" ;;
        F-42)    echo "fedora-42-x86_64" ;;
        F-43)    echo "fedora-43-x86_64" ;;
        SLES-15) echo "opensuse-leap-15.6-x86_64" ;;
        SLES-16) echo "opensuse-leap-16.0-x86_64" ;;
        *)
            log_error "No mock config for distro: ${distro}"
            return 1
            ;;
    esac
}

# Allow override from build-targets.yaml mock_config field
MOCK_CONFIG_OVERRIDE="${MOCK_CONFIG_OVERRIDE:-}"

# Additional mock arguments (e.g., --enable-network for builds that need it)
MOCK_EXTRA_ARGS="${MOCK_EXTRA_ARGS:-}"

# ─── Dependency Check ──────────────────────────────────────────────────────

builder_mock_check_deps() {
    require_command mock "Mock (sudo dnf install mock)" || return 1
    require_command rpmbuild "rpmbuild (sudo dnf install rpm-build)" || return 1
    require_command spectool "spectool (sudo dnf install rpmdevtools)" || return 1

    # Check mock group membership
    if ! groups 2>/dev/null | grep -qw mock; then
        log_warn "Current user is not in the 'mock' group."
        log_warn "Run: sudo usermod -a -G mock \$(whoami) && newgrp mock"
    fi

    log_success "Mock build environment ready"
    return 0
}

# ─── Build RPM ─────────────────────────────────────────────────────────────

# Build an RPM package using Mock.
# Usage: builder_mock_build_rpm <package> <distro> <pg_major> <pg_full> <pg_release> [output_base]
builder_mock_build_rpm() {
    local package="$1"
    local distro="$2"
    local pg_major="$3"
    local pg_full="$4"
    local pg_release="$5"
    local output_base="${6:-${BUILDENV_PROJECT_ROOT}/output}"

    local mock_config
    if [[ -n "${MOCK_CONFIG_OVERRIDE}" ]]; then
        mock_config="${MOCK_CONFIG_OVERRIDE}"
    else
        mock_config=$(_mock_config_for_distro "$distro") || return 1
    fi

    local build_dir
    build_dir=$(init_build_output "mock" "$distro" "$package" "$output_base")
    local log_file
    log_file=$(get_build_log "mock" "$distro" "$package" "$output_base")

    # Find spec file
    local spec_file=""
    local pkg_dir=""
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

    log_build "[mock] ${package} (PG${pg_major} ${pg_full}-${pg_release}) -> ${distro}"
    log_info "Mock config: ${mock_config}"
    log_info "Spec file:   ${spec_file}"
    log_info "Output:      ${build_dir}"
    log_info "Log:         ${log_file}"

    # Step 1: Download sources using spectool
    log_step "Downloading sources..."
    (
        cd "$pkg_dir"
        spectool -g -S \
            --define "pgmajorversion ${pg_major}" \
            --define "pginstdir /usr/pgsql-${pg_major}" \
            --define "pgpackageversion ${pg_major}" \
            "$spec_file" 2>&1 || true
    ) | tee -a "${log_file}"

    # Step 2: Build SRPM locally first (mock needs an SRPM)
    log_step "Building SRPM..."
    local srpm_dir
    srpm_dir=$(mktemp -d)

    rpmbuild \
        --define "_sourcedir ${pkg_dir}" \
        --define "_specdir ${pkg_dir}" \
        --define "_srcrpmdir ${srpm_dir}" \
        --define "_builddir ${srpm_dir}/BUILD" \
        --define "_buildrootdir ${srpm_dir}/BUILDROOT" \
        --define "_rpmdir ${srpm_dir}/RPMS" \
        --define "pgmajorversion ${pg_major}" \
        --define "pginstdir /usr/pgsql-${pg_major}" \
        --define "pgpackageversion ${pg_major}" \
        --nodeps -bs "$spec_file" 2>&1 | tee -a "${log_file}"

    local srpm_file
    srpm_file=$(find "${srpm_dir}" -name '*.src.rpm' -print -quit 2>/dev/null)

    if [[ -z "$srpm_file" ]]; then
        log_error "Failed to build SRPM"
        rm -rf "$srpm_dir"
        return 1
    fi

    log_info "SRPM: ${srpm_file}"

    # Step 3: Build with mock
    log_step "Building with mock (${mock_config})..."
    local mock_resultdir="${build_dir}/mock-results"
    mkdir -p "${mock_resultdir}"

    mock \
        -r "$mock_config" \
        --resultdir="${mock_resultdir}" \
        --define "pgmajorversion ${pg_major}" \
        --define "pginstdir /usr/pgsql-${pg_major}" \
        --define "pgpackageversion ${pg_major}" \
        ${MOCK_EXTRA_ARGS} \
        --rebuild "$srpm_file" 2>&1 | tee -a "${log_file}"

    local rc=$?

    # Step 4: Collect artifacts
    if [[ $rc -eq 0 ]]; then
        log_step "Collecting artifacts..."

        # Copy RPMs to segregated output
        for rpm_file in "${mock_resultdir}"/*.rpm; do
            [[ -f "$rpm_file" ]] || continue
            if [[ "$rpm_file" == *.src.rpm ]]; then
                cp -v "$rpm_file" "${build_dir}/SRPMS/" 2>&1 | tee -a "${log_file}"
            else
                local arch
                arch=$(rpm -qp --queryformat '%{ARCH}' "$rpm_file" 2>/dev/null || echo "x86_64")
                mkdir -p "${build_dir}/RPMS/${arch}"
                cp -v "$rpm_file" "${build_dir}/RPMS/${arch}/" 2>&1 | tee -a "${log_file}"
            fi
        done

        log_success "[mock] ${package} for ${distro} completed"
        organize_rpm_output "${build_dir}" "${distro}" "${output_base}"
        summarize_build_output "${build_dir}"
    else
        log_error "[mock] ${package} for ${distro} FAILED (see ${log_file})"
        # Copy mock logs for debugging
        for mock_log in "${mock_resultdir}"/*.log; do
            [[ -f "$mock_log" ]] && cp "$mock_log" "$(dirname "${log_file}")/"
        done
    fi

    rm -rf "$srpm_dir"
    return $rc
}

# ─── Build DEB (not supported) ────────────────────────────────────────────

builder_mock_build_deb() {
    log_error "Mock does not support DEB builds. Use 'pbuilder' or 'docker' instead."
    return 1
}

# ─── Shell ─────────────────────────────────────────────────────────────────

# Open an interactive shell in a mock chroot.
# Usage: builder_mock_shell <distro>
builder_mock_shell() {
    local distro="$1"

    local mock_config
    if [[ -n "${MOCK_CONFIG_OVERRIDE}" ]]; then
        mock_config="${MOCK_CONFIG_OVERRIDE}"
    else
        mock_config=$(_mock_config_for_distro "$distro") || return 1
    fi

    log_info "[mock] Opening shell in ${distro} mock chroot (${mock_config})..."
    mock -r "$mock_config" --shell
}

# ─── Clean ─────────────────────────────────────────────────────────────────

# Clean mock caches and chroots.
# Usage: builder_mock_clean [distro]
builder_mock_clean() {
    local distro="${1:-}"

    if [[ -n "$distro" ]]; then
        local mock_config
        mock_config=$(_mock_config_for_distro "$distro") || return 1
        log_step "[mock] Cleaning chroot for ${distro}..."
        mock -r "$mock_config" --clean
    else
        log_step "[mock] Cleaning all mock caches..."
        mock --clean 2>/dev/null || true
        mock --scrub=all 2>/dev/null || true
    fi

    log_success "[mock] Cleanup complete"
}
