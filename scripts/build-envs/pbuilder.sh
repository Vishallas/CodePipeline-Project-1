#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# pbuilder.sh — pbuilder/cowbuilder build environment driver
# ─────────────────────────────────────────────────────────────────────────────
#
# Builds DEB packages using pbuilder (or cowbuilder for faster COW-based
# chroots). These are the standard Debian/Ubuntu clean-room build tools.
#
# pbuilder creates a base chroot tarball for each distribution and unpacks
# it for each build, ensuring a clean environment. cowbuilder uses
# copy-on-write for faster builds.
#
# Required tools: pbuilder (or cowbuilder), debootstrap, dpkg-dev
#
# Setup:
#   sudo apt install pbuilder debootstrap devscripts dpkg-dev cowbuilder
#   sudo pbuilder create --distribution bookworm
#
# ─────────────────────────────────────────────────────────────────────────────

DRIVER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${DRIVER_DIR}/common.sh"

# ─── Configuration ─────────────────────────────────────────────────────────

# Use cowbuilder by default if available (faster COW-based builds)
PBUILDER_CMD="${PBUILDER_CMD:-auto}"

# Base path for pbuilder chroots
PBUILDER_BASE="${PBUILDER_BASE:-/var/cache/pbuilder}"

# Mirror for debootstrap
DEBIAN_MIRROR="${DEBIAN_MIRROR:-http://deb.debian.org/debian}"
UBUNTU_MIRROR="${UBUNTU_MIRROR:-http://archive.ubuntu.com/ubuntu}"

# Additional pbuilder arguments
PBUILDER_EXTRA_ARGS="${PBUILDER_EXTRA_ARGS:-}"

# Map dist codenames to their settings
_pbuilder_dist_info() {
    local dist="$1"
    case "$dist" in
        bookworm)
            echo "debian|bookworm|${DEBIAN_MIRROR}" ;;
        bullseye)
            echo "debian|bullseye|${DEBIAN_MIRROR}" ;;
        trixie)
            echo "debian|trixie|${DEBIAN_MIRROR}" ;;
        jammy)
            echo "ubuntu|jammy|${UBUNTU_MIRROR}" ;;
        noble)
            echo "ubuntu|noble|${UBUNTU_MIRROR}" ;;
        focal)
            echo "ubuntu|focal|${UBUNTU_MIRROR}" ;;
        *)
            log_error "Unknown distribution: ${dist}"
            log_error "Supported: bookworm, bullseye, trixie, jammy, noble, focal"
            return 1
            ;;
    esac
}

_resolve_pbuilder_cmd() {
    if [[ "$PBUILDER_CMD" == "auto" ]]; then
        if command -v cowbuilder &>/dev/null; then
            PBUILDER_CMD="cowbuilder"
        elif command -v pbuilder &>/dev/null; then
            PBUILDER_CMD="pbuilder"
        else
            log_error "Neither cowbuilder nor pbuilder found"
            return 1
        fi
    fi
    echo "$PBUILDER_CMD"
}

# ─── Dependency Check ──────────────────────────────────────────────────────

builder_pbuilder_check_deps() {
    local cmd
    cmd=$(_resolve_pbuilder_cmd) || return 1
    require_command "$cmd" "$cmd (sudo apt install pbuilder cowbuilder)" || return 1
    require_command debootstrap "debootstrap (sudo apt install debootstrap)" || return 1
    require_command dpkg-buildpackage "dpkg-dev (sudo apt install dpkg-dev)" || return 1

    log_success "pbuilder/cowbuilder build environment ready (${cmd})"
    return 0
}

# ─── Chroot Management ────────────────────────────────────────────────────

_pbuilder_basetgz() {
    local dist="$1"
    local info
    info=$(_pbuilder_dist_info "$dist") || return 1
    local os codename
    IFS='|' read -r os codename _mirror <<< "$info"

    local cmd
    cmd=$(_resolve_pbuilder_cmd)
    if [[ "$cmd" == "cowbuilder" ]]; then
        echo "${PBUILDER_BASE}/base-${codename}.cow"
    else
        echo "${PBUILDER_BASE}/base-${codename}.tgz"
    fi
}

# Ensure a pbuilder base chroot exists for the distribution.
# Usage: builder_pbuilder_ensure_chroot <dist>
builder_pbuilder_ensure_chroot() {
    local dist="$1"
    local info
    info=$(_pbuilder_dist_info "$dist") || return 1
    local os codename mirror
    IFS='|' read -r os codename mirror <<< "$info"

    local cmd
    cmd=$(_resolve_pbuilder_cmd)
    local basetgz
    basetgz=$(_pbuilder_basetgz "$dist")

    if [[ "$cmd" == "cowbuilder" ]]; then
        if [[ -d "$basetgz" ]]; then
            log_info "cowbuilder base exists: ${basetgz}"
            return 0
        fi
    else
        if [[ -f "$basetgz" ]]; then
            log_info "pbuilder base exists: ${basetgz}"
            return 0
        fi
    fi

    log_step "Creating ${cmd} base for ${dist} (${codename})..."

    local components="main"
    [[ "$os" == "ubuntu" ]] && components="main universe"

    sudo ${cmd} --create \
        --distribution "$codename" \
        --mirror "$mirror" \
        --components "$components" \
        --basetgz "$basetgz" \
        --debootstrapopts --variant=buildd

    log_success "Created ${cmd} base: ${basetgz}"
}

# ─── Build DEB ─────────────────────────────────────────────────────────────

# Build a DEB package using pbuilder/cowbuilder.
# Usage: builder_pbuilder_build_deb <package> <dist> <pg_major> <pg_full> <pg_release> [output_base]
builder_pbuilder_build_deb() {
    local package="$1"
    local dist="$2"
    local pg_major="$3"
    local pg_full="$4"
    local pg_release="$5"
    local output_base="${6:-${BUILDENV_PROJECT_ROOT}/output}"

    local cmd
    cmd=$(_resolve_pbuilder_cmd) || return 1

    # Ensure the chroot exists
    builder_pbuilder_ensure_chroot "$dist" || return 1

    local build_dir
    build_dir=$(init_build_output "pbuilder" "$dist" "$package" "$output_base")
    local log_file
    log_file=$(get_build_log "pbuilder" "$dist" "$package" "$output_base")

    local basetgz
    basetgz=$(_pbuilder_basetgz "$dist")

    log_build "[pbuilder] DEB ${package} (PG${pg_major} ${pg_full}-${pg_release}) -> ${dist}"
    log_info "Builder: ${cmd}"
    log_info "Base:    ${basetgz}"
    log_info "Output:  ${build_dir}"
    log_info "Log:     ${log_file}"

    # Step 1: Prepare source package (source extraction happens inside chroot)
    log_step "Preparing source package materials..."
    local work_dir
    work_dir=$(mktemp -d)

    (
        cd "$work_dir"

        # Download PostgreSQL source
        log_info "Downloading PostgreSQL ${pg_full} source..."
        wget -q "https://ftp.postgresql.org/pub/source/v${pg_full}/postgresql-${pg_full}.tar.bz2" || {
            log_error "Failed to download source"
            exit 1
        }

        # Create orig tarball (Debian convention)
        # This is required by Debian packaging standards
        cp "postgresql-${pg_full}.tar.bz2" "postgresql-${pg_major}_${pg_full}.orig.tar.bz2"

        # Prepare debian/ directory with templated files
        # This must happen on host since we need to generate files from templates
        log_info "Generating Debian packaging files from templates..."
        mkdir -p "postgresql-${pg_full}/debian"

        local debian_source_dir="${BUILDENV_PROJECT_ROOT}/debian/main/non-common/postgresql-${pg_major}/debian"
        if [[ -d "${debian_source_dir}" ]]; then
            log_info "Using Debian files from: ${debian_source_dir}"
            # Copy template files
            for file in "${debian_source_dir}"/*; do
                [[ -f "$file" ]] || continue
                cp "$file" "postgresql-${pg_full}/debian/"
            done

            # Generate actual files from templates by replacing placeholders
            for template_file in "postgresql-${pg_full}"/debian/*.in; do
                if [[ -f "${template_file}" ]]; then
                    output_file="${template_file%.in}"
                    log_info "Generating $(basename ${output_file}) from template..."
                    python3 "${BUILDENV_PROJECT_ROOT}/scripts/generate-control.py" \
                        --template "${template_file}" \
                        --output "${output_file}" \
                        --major "${pg_major}" \
                        --full "${pg_full}" \
                        --release "${pg_release}" \
                        --dist "${dist}" 2>/dev/null || true
                    rm -f "${template_file}"
                fi
            done
        elif [[ -f "${BUILDENV_PROJECT_ROOT}/packaging/debian/control.in" ]]; then
            log_warn "Using legacy template from ${BUILDENV_PROJECT_ROOT}/packaging/debian/"
            log_warn "Recommended: Run 'scripts/generate-debian-structure.sh' to create folder structure"
            python3 "${BUILDENV_PROJECT_ROOT}/scripts/generate-control.py" \
                --template "${BUILDENV_PROJECT_ROOT}/packaging/debian/control.in" \
                --output "postgresql-${pg_full}/debian/control" \
                --major "${pg_major}" 2>/dev/null || true
        fi

        # Create minimal debian files if missing
        if [[ ! -f "postgresql-${pg_full}/debian/changelog" ]]; then
            cat > "postgresql-${pg_full}/debian/changelog" << CHLOG
postgresql-${pg_major} (${pg_full}-${pg_release}) ${dist}; urgency=medium

  * Package build via packaging-postgresql build system.

 -- PostgreSQL Packaging <packaging@example.com>  $(date -R)
CHLOG
        fi

        if [[ ! -f "postgresql-${pg_full}/debian/rules" ]]; then
            cat > "postgresql-${pg_full}/debian/rules" << 'RULES'
#!/usr/bin/make -f
%:
	dh $@
RULES
            chmod +x "postgresql-${pg_full}/debian/rules"
        fi

        if [[ ! -f "postgresql-${pg_full}/debian/compat" ]]; then
            echo "13" > "postgresql-${pg_full}/debian/compat"
        fi

        # Build the source package (.dsc) on host
        # NOTE: Source extraction (tar -xjf) is NOT done here
        # Source extraction happens inside the pbuilder chroot during build
        cd "postgresql-${pg_full}"
        dpkg-source -b . 2>&1 || true
        cd ..

    ) 2>&1 | tee -a "${log_file}"

    # Find the .dsc file
    local dsc_file
    dsc_file=$(find "${work_dir}" -maxdepth 1 -name '*.dsc' -print -quit 2>/dev/null)

    if [[ -z "$dsc_file" ]]; then
        log_error "Failed to create source package (.dsc)"
        rm -rf "$work_dir"
        return 1
    fi

    # Step 2: Build with pbuilder/cowbuilder
    # Source extraction happens INSIDE the chroot during this step
    log_step "Building with ${cmd} (source extraction happens in chroot)..."

    local pbuilder_resultdir="${build_dir}/pbuilder-results"
    mkdir -p "${pbuilder_resultdir}"

    sudo ${cmd} --build \
        --basetgz "$basetgz" \
        --buildresult "${pbuilder_resultdir}" \
        ${PBUILDER_EXTRA_ARGS} \
        "$dsc_file" 2>&1 | tee -a "${log_file}"

    local rc=$?

    # Step 3: Collect artifacts
    if [[ $rc -eq 0 ]]; then
        log_step "Collecting artifacts..."

        for deb_file in "${pbuilder_resultdir}"/*.deb; do
            [[ -f "$deb_file" ]] || continue
            cp -v "$deb_file" "${build_dir}/DEBS/" 2>&1 | tee -a "${log_file}"
        done

        # Also copy changes and buildinfo files
        for meta_file in "${pbuilder_resultdir}"/*.changes "${pbuilder_resultdir}"/*.buildinfo; do
            [[ -f "$meta_file" ]] || continue
            cp -v "$meta_file" "${build_dir}/DEBS/" 2>&1 | tee -a "${log_file}"
        done

        log_success "[pbuilder] DEB ${package} for ${dist} completed"
        organize_deb_output "${build_dir}" "${dist}" "${output_base}"
        summarize_build_output "${build_dir}"
    else
        log_error "[pbuilder] DEB ${package} for ${dist} FAILED (see ${log_file})"
    fi

    rm -rf "$work_dir"
    return $rc
}

# ─── Build RPM (not supported) ────────────────────────────────────────────

builder_pbuilder_build_rpm() {
    log_error "pbuilder does not support RPM builds. Use 'mock' or 'docker' instead."
    return 1
}

# ─── Shell ─────────────────────────────────────────────────────────────────

# Open an interactive shell in a pbuilder chroot.
# Usage: builder_pbuilder_shell <dist>
builder_pbuilder_shell() {
    local dist="$1"

    builder_pbuilder_ensure_chroot "$dist" || return 1

    local cmd
    cmd=$(_resolve_pbuilder_cmd)
    local basetgz
    basetgz=$(_pbuilder_basetgz "$dist")

    log_info "[pbuilder] Opening shell in ${dist} chroot..."
    sudo ${cmd} --login --basetgz "$basetgz"
}

# ─── Setup ─────────────────────────────────────────────────────────────────

# Create base chroots for all configured distributions.
# Usage: builder_pbuilder_setup
builder_pbuilder_setup() {
    log_step "[pbuilder] Creating base chroots for all distributions..."

    local dists=(bookworm bullseye jammy noble)
    for dist in "${dists[@]}"; do
        builder_pbuilder_ensure_chroot "$dist" || log_warn "Failed to create base for ${dist}"
    done

    log_success "[pbuilder] Setup complete"
}

# ─── Clean ─────────────────────────────────────────────────────────────────

# Remove pbuilder base chroots.
# Usage: builder_pbuilder_clean [dist]
builder_pbuilder_clean() {
    local dist="${1:-}"

    if [[ -n "$dist" ]]; then
        local basetgz
        basetgz=$(_pbuilder_basetgz "$dist") || return 1
        log_step "[pbuilder] Removing base for ${dist}..."
        sudo rm -rf "$basetgz"
    else
        log_step "[pbuilder] Cleaning all pbuilder bases..."
        sudo rm -rf "${PBUILDER_BASE}"/base-*.tgz "${PBUILDER_BASE}"/base-*.cow
    fi

    log_success "[pbuilder] Cleanup complete"
}
