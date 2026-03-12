#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# sbuild.sh — sbuild/schroot build environment driver
# ─────────────────────────────────────────────────────────────────────────────
#
# Builds DEB packages using sbuild, the standard Debian/Ubuntu clean-room
# build tool. sbuild uses schroot for chroot management with better features
# than pbuilder: snapshots, rollback, apt-cache, multi-arch, and reproducibility.
#
# sbuild creates named chroot configurations via schroot that provide:
# - Clean environment for each build
# - Isolated from host system
# - Built-in apt caching
# - Better snapshot/rollback support
# - Multi-arch build capability
# - Better for reproducible builds
#
# Required tools:
#   sudo apt install sbuild schroot mmdebstrap devscripts
#   sudo usermod -aG sbuild $(whoami)  # Add user to sbuild group
#   newgrp sbuild                       # Activate group membership
#
# Setup (creates named chroot with mmdebstrap):
#   sudo sbuild-createchroot --make-sbuild-tarball=/tmp/bookworm-amd64.tar \
#       --debootstrap=mmdebstrap bookworm /srv/sbuild/bookworm-amd64 http://deb.debian.org/debian
#
# ─────────────────────────────────────────────────────────────────────────────

DRIVER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${DRIVER_DIR}/common.sh"

# ─── Configuration ─────────────────────────────────────────────────────────

# Base path for sbuild chroots (schroot location)
SBUILD_CHROOT_BASE="${SBUILD_CHROOT_BASE:-/srv/sbuild}"

# Architecture to build for (usually matches host)
SBUILD_ARCH="${SBUILD_ARCH:-amd64}"

# Additional sbuild options
SBUILD_EXTRA_OPTS="${SBUILD_EXTRA_OPTS:-}"

# APT cache location (optional, speeds up repeated builds)
SBUILD_APT_CACHE="${SBUILD_APT_CACHE:-/var/cache/apt/archives}"

# Map dist codenames to their settings
_sbuild_dist_info() {
    local dist="$1"
    case "$dist" in
        bookworm)
            echo "debian|bookworm|${DEBIAN_MIRROR:-http://deb.debian.org/debian}|main contrib non-free non-free-firmware" ;;
        bullseye)
            echo "debian|bullseye|${DEBIAN_MIRROR:-http://deb.debian.org/debian}|main contrib non-free" ;;
        trixie)
            echo "debian|trixie|${DEBIAN_MIRROR:-http://deb.debian.org/debian}|main contrib non-free non-free-firmware" ;;
        sid)
            echo "debian|sid|${DEBIAN_MIRROR:-http://deb.debian.org/debian}|main contrib non-free non-free-firmware" ;;
        jammy)
            echo "ubuntu|jammy|${UBUNTU_MIRROR:-http://archive.ubuntu.com/ubuntu}|main universe" ;;
        noble)
            echo "ubuntu|noble|${UBUNTU_MIRROR:-http://archive.ubuntu.com/ubuntu}|main universe" ;;
        focal)
            echo "ubuntu|focal|${UBUNTU_MIRROR:-http://archive.ubuntu.com/ubuntu}|main universe" ;;
        *)
            log_error "Unknown distribution: ${dist}"
            log_error "Supported: bookworm, bullseye, trixie, sid, jammy, noble, focal"
            return 1
            ;;
    esac
}

# ─── Dependency Check ──────────────────────────────────────────────────────

builder_sbuild_check_deps() {
    require_command sbuild "sbuild (sudo apt install sbuild)" || return 1
    require_command schroot "schroot (sudo apt install schroot)" || return 1
    require_command sbuild-createchroot "sbuild (sudo apt install sbuild)" || return 1
    require_command mmdebstrap "mmdebstrap (sudo apt install mmdebstrap)" || return 1
    require_command dpkg-buildpackage "dpkg-dev (sudo apt install dpkg-dev)" || return 1

    log_success "sbuild + mmdebstrap build environment ready"
    return 0
}

# ─── Chroot Management ────────────────────────────────────────────────────

# Get schroot chroot name for distribution
_sbuild_chroot_name() {
    local dist="$1"
    local arch="${2:-${SBUILD_ARCH}}"
    echo "${dist}-${arch}"
}

# Ensure sbuild chroot exists for the distribution
# Usage: builder_sbuild_ensure_chroot <dist>
builder_sbuild_ensure_chroot() {
    local dist="$1"
    local info
    info=$(_sbuild_dist_info "$dist") || return 1
    local os codename mirror components
    IFS='|' read -r os codename mirror components <<< "$info"

    local chroot_name
    chroot_name=$(_sbuild_chroot_name "$dist")

    local chroot_path="${SBUILD_CHROOT_BASE}/${chroot_name}"

    # Check if chroot already exists via schroot
    if schroot -l | grep -q "chroot:${chroot_name}"; then
        log_info "sbuild chroot exists: ${chroot_name}"
        return 0
    fi

    log_step "Creating sbuild chroot for ${dist} (${codename}) with mmdebstrap..."

    # Use mmdebstrap for faster chroot creation (5-15 min vs 20-40 min)
    # mmdebstrap is significantly faster than debootstrap
    sudo sbuild-createchroot \
        --make-sbuild-tarball=/tmp/sbuild-${codename}-${SBUILD_ARCH}.tar.gz \
        --debootstrap=mmdebstrap \
        --include=build-essential,fakeroot,devscripts,lintian \
        --arch="${SBUILD_ARCH}" \
        --skip-keyring \
        "$codename" \
        "$chroot_path" \
        "$mirror" || {
        log_error "Failed to create sbuild chroot with mmdebstrap"
        return 1
    }

    log_success "Created sbuild chroot with mmdebstrap: ${chroot_name}"
}

# Update sbuild chroot packages
# Usage: builder_sbuild_update_chroot <dist>
builder_sbuild_update_chroot() {
    local dist="$1"
    local chroot_name
    chroot_name=$(_sbuild_chroot_name "$dist")

    log_step "Updating sbuild chroot: ${chroot_name}..."

    sudo sbuild-update --update --dist-upgrade "$chroot_name" || {
        log_warn "Failed to update sbuild chroot (this is non-fatal)"
    }

    log_success "Updated sbuild chroot: ${chroot_name}"
}

# ─── Build DEB ─────────────────────────────────────────────────────────────

# Build a DEB package using sbuild.
# Usage: builder_sbuild_build_deb <package> <dist> <pg_major> <pg_full> <pg_release> [output_base]
builder_sbuild_build_deb() {
    local package="$1"
    local dist="$2"
    local pg_major="$3"
    local pg_full="$4"
    local pg_release="$5"
    local output_base="${6:-${BUILDENV_PROJECT_ROOT}/output}"

    # Ensure the chroot exists
    builder_sbuild_ensure_chroot "$dist" || return 1

    local build_dir
    build_dir=$(init_build_output "sbuild" "$dist" "$package" "$output_base")
    local log_file
    log_file=$(get_build_log "sbuild" "$dist" "$package" "$output_base")

    local chroot_name
    chroot_name=$(_sbuild_chroot_name "$dist")

    log_build "[sbuild] DEB ${package} (PG${pg_major} ${pg_full}-${pg_release}) -> ${dist}"
    log_info "Chroot:  ${chroot_name}"
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

        # Look for distro-specific debian files first, then main, then packaging
        local debian_source_dir=""
        if [[ -d "${BUILDENV_PROJECT_ROOT}/debian/main/non-common/postgresql-${pg_major}/${dist}/debian" ]]; then
            debian_source_dir="${BUILDENV_PROJECT_ROOT}/debian/main/non-common/postgresql-${pg_major}/${dist}/debian"
        elif [[ -d "${BUILDENV_PROJECT_ROOT}/debian/main/non-common/postgresql-${pg_major}/main/debian" ]]; then
            debian_source_dir="${BUILDENV_PROJECT_ROOT}/debian/main/non-common/postgresql-${pg_major}/main/debian"
        fi

        if [[ -n "${debian_source_dir}" && -d "${debian_source_dir}" ]]; then
            log_info "Using Debian files from: ${debian_source_dir}"
            # Copy files (excluding patches subdirectory), following symlinks
            for file in "${debian_source_dir}"/*; do
                [[ -f "$file" ]] || [[ -L "$file" ]] || continue
                cp -L "$file" "postgresql-${pg_full}/debian/"
            done

            # Copy patches if they exist
            if [[ -d "${debian_source_dir}/patches" ]]; then
                mkdir -p "postgresql-${pg_full}/debian/patches"
                cp -r "${debian_source_dir}/patches"/* "postgresql-${pg_full}/debian/patches/" 2>/dev/null || true
            fi

            # Update changelog version to match the one being built
            if [[ -f "postgresql-${pg_full}/debian/changelog" ]]; then
                log_info "Updating changelog version to ${pg_full}-${pg_release}..."
                # Update the first line to have the correct version
                sed -i "1s/postgresql-${pg_major} ([^)]*)/postgresql-${pg_major} (${pg_full}-${pg_release})/" \
                    "postgresql-${pg_full}/debian/changelog"
            fi

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
        # Source extraction happens inside the sbuild chroot during build
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

    # Find the .changes file (required by sbuild)
    local changes_file
    changes_file=$(find "${work_dir}" -maxdepth 1 -name '*.changes' -print -quit 2>/dev/null)

    if [[ -z "$changes_file" ]]; then
        log_warn "No .changes file found, sbuild may require it"
    fi

    # Step 2: Build with sbuild
    # Source extraction happens INSIDE the chroot during this step
    log_step "Building with sbuild (source extraction happens in chroot)..."

    # sbuild requires the .dsc file to be in current directory
    cd "$work_dir"

    sbuild \
        --chroot="${chroot_name}" \
        --arch="${SBUILD_ARCH}" \
        ${SBUILD_EXTRA_OPTS} \
        "$dsc_file" 2>&1 | tee -a "${log_file}"

    local rc=$?
    cd - > /dev/null

    # Step 3: Collect artifacts
    if [[ $rc -eq 0 ]]; then
        log_step "Collecting artifacts..."

        # sbuild puts built packages in parent directory of .dsc
        for deb_file in "${work_dir}"/../*.deb; do
            [[ -f "$deb_file" ]] || continue
            cp -v "$deb_file" "${build_dir}/DEBS/" 2>&1 | tee -a "${log_file}"
        done

        # Also copy changes and buildinfo files
        for meta_file in "${work_dir}"/../*.changes "${work_dir}"/../*.buildinfo; do
            [[ -f "$meta_file" ]] || continue
            cp -v "$meta_file" "${build_dir}/DEBS/" 2>&1 | tee -a "${log_file}"
        done

        log_success "[sbuild] DEB ${package} for ${dist} completed"
        organize_deb_output "${build_dir}" "${dist}" "${output_base}"
        summarize_build_output "${build_dir}"
    else
        log_error "[sbuild] DEB ${package} for ${dist} FAILED (see ${log_file})"
    fi

    rm -rf "$work_dir"
    return $rc
}

# ─── Build RPM (not supported) ────────────────────────────────────────────

builder_sbuild_build_rpm() {
    log_error "sbuild does not support RPM builds. Use 'mock' or 'docker' instead."
    return 1
}

# ─── Shell ─────────────────────────────────────────────────────────────────

# Open an interactive shell in an sbuild chroot.
# Usage: builder_sbuild_shell <dist>
builder_sbuild_shell() {
    local dist="$1"

    builder_sbuild_ensure_chroot "$dist" || return 1

    local chroot_name
    chroot_name=$(_sbuild_chroot_name "$dist")

    log_info "[sbuild] Opening shell in ${dist} chroot..."
    schroot -c "$chroot_name" --user="$USER" -i
}

# ─── Setup ─────────────────────────────────────────────────────────────────

# Create sbuild chroots for all configured distributions.
# Usage: builder_sbuild_setup
builder_sbuild_setup() {
    log_step "[sbuild] Creating chroots for all distributions..."

    local dists=(bookworm bullseye jammy noble)
    for dist in "${dists[@]}"; do
        builder_sbuild_ensure_chroot "$dist" || log_warn "Failed to create chroot for ${dist}"
    done

    log_success "[sbuild] Setup complete"
}

# ─── Update ────────────────────────────────────────────────────────────────

# Update sbuild chroots with latest packages
# Usage: builder_sbuild_update [dist]
builder_sbuild_update() {
    local dist="${1:-}"

    if [[ -n "$dist" ]]; then
        builder_sbuild_update_chroot "$dist"
    else
        log_step "[sbuild] Updating all chroots..."
        local dists=(bookworm bullseye jammy noble)
        for d in "${dists[@]}"; do
            builder_sbuild_update_chroot "$d" || log_warn "Failed to update ${d}"
        done
        log_success "[sbuild] All chroots updated"
    fi
}

# ─── Clean ─────────────────────────────────────────────────────────────────

# Remove sbuild chroots (schroot configuration).
# Usage: builder_sbuild_clean [dist]
builder_sbuild_clean() {
    local dist="${1:-}"

    if [[ -n "$dist" ]]; then
        local chroot_name
        chroot_name=$(_sbuild_chroot_name "$dist")

        log_step "[sbuild] Removing chroot: ${chroot_name}..."

        # Remove schroot configuration
        sudo schroot -c "$chroot_name" --end-session || true

        # Remove filesystem
        sudo rm -rf "${SBUILD_CHROOT_BASE}/${chroot_name}"

        log_success "[sbuild] Removed chroot: ${chroot_name}"
    else
        log_step "[sbuild] Cleaning all sbuild chroots..."

        # List all sbuild chroots and remove them
        for chroot in $(schroot -l | grep "chroot:" | sed 's/chroot://'); do
            sudo schroot -c "$chroot" --end-session || true
            sudo rm -rf "${SBUILD_CHROOT_BASE}/${chroot}"
        done

        log_success "[sbuild] Cleanup complete"
    fi
}

# ─── List ──────────────────────────────────────────────────────────────────

# List available sbuild chroots
# Usage: builder_sbuild_list
builder_sbuild_list() {
    log_info "Available sbuild chroots:"
    schroot -l | grep "chroot:" || log_warn "No sbuild chroots found"
}

# ─── Status ────────────────────────────────────────────────────────────────

# Show sbuild configuration and status
# Usage: builder_sbuild_status
builder_sbuild_status() {
    log_info "sbuild configuration:"
    log_info "  Chroot base: ${SBUILD_CHROOT_BASE}"
    log_info "  Architecture: ${SBUILD_ARCH}"
    log_info "  APT cache: ${SBUILD_APT_CACHE}"
    log_info ""
    log_info "Available chroots:"
    schroot -l | grep "chroot:" | sed 's/^/  /' || log_warn "No sbuild chroots found"
}
