#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# docker.sh — Docker build environment driver
# ─────────────────────────────────────────────────────────────────────────────
#
# Builds packages inside Docker containers. This is the default and most
# isolated build environment, suitable for all platforms.
#
# Required tools: docker (or podman), docker-compose (optional)
#
# ─────────────────────────────────────────────────────────────────────────────

DRIVER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${DRIVER_DIR}/common.sh"

# ─── Configuration ─────────────────────────────────────────────────────────

# Override with DOCKER_CMD=podman for Podman compatibility
DOCKER_CMD="${DOCKER_CMD:-docker}"
DOCKER_IMAGE_PREFIX="${DOCKER_IMAGE_PREFIX:-postgresql-build}"
DOCKER_COMPOSE_FILE="${BUILDENV_PROJECT_ROOT}/docker/docker-compose.yml"

# ─── Dependency Check ──────────────────────────────────────────────────────

builder_docker_check_deps() {
    if ! command -v "$DOCKER_CMD" &>/dev/null; then
        # Fall back to podman if docker not found
        if command -v podman &>/dev/null; then
            DOCKER_CMD="podman"
            log_info "Using podman as Docker alternative"
        else
            log_error "Neither docker nor podman found. Install one of them."
            return 1
        fi
    fi
    log_success "Docker build environment ready (${DOCKER_CMD})"
    return 0
}

# ─── Helpers ───────────────────────────────────────────────────────────────

_docker_image_tag() {
    local distro="$1"
    case "$distro" in
        AMZ2023)   echo "amazonlinux2023" ;;
        AMZN-2023) echo "amazonlinux2023" ;;
        EL-8)      echo "el8" ;;
        EL-9)      echo "el9" ;;
        EL-10)     echo "el10" ;;
        F-42)      echo "fedora42" ;;
        F-43)      echo "fedora43" ;;
        SLES-15)   echo "sles15" ;;
        SLES-16)   echo "sles16" ;;
        CS-9)      echo "centos-stream9" ;;
        # DEB distros - map to their dockerfile directory names
        bookworm)  echo "debian-bookworm" ;;
        bullseye)  echo "debian-bullseye" ;;
        jammy)     echo "ubuntu-jammy" ;;
        noble)     echo "ubuntu-noble" ;;
        focal)     echo "ubuntu-focal" ;;
        *)
            # Fallback: try lowercase with hyphens first, then without hyphens
            local candidate
            candidate=$(echo "$distro" | tr '[:upper:]' '[:lower:]')
            if [[ -d "${BUILDENV_PROJECT_ROOT}/docker/${candidate}" ]]; then
                echo "$candidate"
            else
                candidate=$(echo "$distro" | tr '[:upper:]' '[:lower:]' | tr -d '-')
                echo "$candidate"
            fi
            ;;
    esac
}

_docker_ensure_image() {
    local distro="$1"
    local tag
    tag=$(_docker_image_tag "$distro")
    local full_image="${DOCKER_IMAGE_PREFIX}:${tag}"

    if ! ${DOCKER_CMD} image inspect "$full_image" &>/dev/null; then
        local dockerfile_dir="${BUILDENV_PROJECT_ROOT}/docker/${tag}"
        if [[ -f "${dockerfile_dir}/Dockerfile" ]]; then
            log_info "Building Docker image: ${full_image}" log_info "Building..." >&2
            if ! ${DOCKER_CMD} build -t "$full_image" "${dockerfile_dir}"; then
                log_error "Failed to build Docker image: ${full_image}"
                return 1
            fi
        else
            log_error "Dockerfile not found: ${dockerfile_dir}/Dockerfile"
            return 1
        fi
    fi
    echo "$full_image"
}

# ─── Build RPM ─────────────────────────────────────────────────────────────

# Build an RPM package inside a Docker container.
# Usage: builder_docker_build_rpm <package> <distro> <pg_major> <pg_full> <pg_release> [output_base]
builder_docker_build_rpm() {
    local package="$1"
    local distro="$2"
    local pg_major="$3"
    local pg_full="$4"
    local pg_release="$5"
    local output_base="${6:-${BUILDENV_PROJECT_ROOT}/output}"

    local full_image
    full_image=$(_docker_ensure_image "$distro") || return 1

    local build_dir
    build_dir=$(init_build_output "docker" "$distro" "$package" "$output_base")
    # Make output dirs writable by the container's builder user (UID 1000)
    chmod -R a+rwX "${build_dir}"
    local log_file
    log_file=$(get_build_log "docker" "$distro" "$package" "$output_base")

    # Determine package directory
    local pkg_dir=""
    if [[ -d "${BUILDENV_PROJECT_ROOT}/rpm/redhat/main/non-common/${package}/${distro}" ]]; then
        pkg_dir="rpm/redhat/main/non-common/${package}/${distro}"
    elif [[ -d "${BUILDENV_PROJECT_ROOT}/rpm/redhat/main/non-common/${package}/main" ]]; then
        pkg_dir="rpm/redhat/main/non-common/${package}/main"
    elif [[ -d "${BUILDENV_PROJECT_ROOT}/rpm/redhat/main/common/${package}/${distro}" ]]; then
        pkg_dir="rpm/redhat/main/common/${package}/${distro}"
    elif [[ -d "${BUILDENV_PROJECT_ROOT}/rpm/redhat/main/common/${package}/main" ]]; then
        pkg_dir="rpm/redhat/main/common/${package}/main"
    elif [[ -d "${BUILDENV_PROJECT_ROOT}/rpm/redhat/main/extras/${package}/${distro}" ]]; then
        pkg_dir="rpm/redhat/main/extras/${package}/${distro}"
    elif [[ -d "${BUILDENV_PROJECT_ROOT}/rpm/redhat/main/extras/${package}/main" ]]; then
        pkg_dir="rpm/redhat/main/extras/${package}/main"
    else
        log_error "Package directory not found for: ${package} (distro: ${distro})"
        return 1
    fi

    local make_jobs
    make_jobs=$(nproc 2>/dev/null || echo 4)

    log_build "[docker] ${package} (PG${pg_major} ${pg_full}-${pg_release}) -> ${distro}"
    log_info "Image:   ${full_image}"
    log_info "PkgDir:  ${pkg_dir}"
    log_info "Output:  ${build_dir}"
    log_info "Log:     ${log_file}"

    local container_workdir="/build/${pkg_dir}"

    ${DOCKER_CMD} run --rm \
        -v "${BUILDENV_PROJECT_ROOT}:/build:z" \
        -v "${build_dir}:/output:z" \
        -w "${container_workdir}" \
        -e "HOME=/home/builder" \
        -e "MAKEFLAGS=-j${make_jobs}" \
        "$full_image" \
        bash -c '
            set -e

            SRC_DIR="$(pwd)"
            mkdir -p /home/builder/rpm'"${pg_major}"'/{BUILD,BUILDROOT,RPMS,SRPMS}
            git config --global --add safe.directory /build

            SPEC_FILE=$(ls *.spec 2>/dev/null | head -1)
            if [[ -z "$SPEC_FILE" ]]; then
                echo "ERROR: No spec file found in '"${pkg_dir}"'"
                exit 1
            fi

            echo "==> Downloading sources..."
            spectool -g -S \
                --define "pgmajorversion '"${pg_major}"'" \
                --define "pginstdir /usr/pgsql-'"${pg_major}"'" \
                --define "pgpackageversion '"${pg_major}"'" \
                "$SPEC_FILE" 2>&1 || true

            echo "==> Building RPMs..."
            rpmbuild \
                --define "_sourcedir ${SRC_DIR}" \
                --define "_specdir ${SRC_DIR}" \
                --define "_builddir /home/builder/rpm'"${pg_major}"'/BUILD" \
                --define "_buildrootdir /home/builder/rpm'"${pg_major}"'/BUILDROOT" \
                --define "_srcrpmdir /home/builder/rpm'"${pg_major}"'/SRPMS" \
                --define "_rpmdir /home/builder/rpm'"${pg_major}"'/RPMS/" \
                --define "pgmajorversion '"${pg_major}"'" \
                --define "pginstdir /usr/pgsql-'"${pg_major}"'" \
                --define "pgpackageversion '"${pg_major}"'" \
                -bb "$SPEC_FILE"

            echo "==> Building SRPM..."
            rpmbuild \
                --define "_sourcedir ${SRC_DIR}" \
                --define "_specdir ${SRC_DIR}" \
                --define "_builddir /home/builder/rpm'"${pg_major}"'/BUILD" \
                --define "_buildrootdir /home/builder/rpm'"${pg_major}"'/BUILDROOT" \
                --define "_srcrpmdir /home/builder/rpm'"${pg_major}"'/SRPMS" \
                --define "_rpmdir /home/builder/rpm'"${pg_major}"'/RPMS/" \
                --define "pgmajorversion '"${pg_major}"'" \
                --define "pginstdir /usr/pgsql-'"${pg_major}"'" \
                --define "pgpackageversion '"${pg_major}"'" \
                --nodeps -bs "$SPEC_FILE" || true

            echo "==> Collecting artifacts..."
            find /home/builder/rpm'"${pg_major}"'/RPMS/ -name "*.rpm" | while read f; do
                arch=$(rpm -qp --queryformat "%{ARCH}" "$f" 2>/dev/null || echo "x86_64")
                mkdir -p /output/RPMS/${arch}
                cp -v "$f" /output/RPMS/${arch}/
            done
            find /home/builder/rpm'"${pg_major}"'/SRPMS/ -name "*.src.rpm" -exec cp -v {} /output/SRPMS/ \; 2>/dev/null || true

            echo "==> Build complete!"
        ' 2>&1 | tee "${log_file}"

    local rc=${PIPESTATUS[0]}

    if [[ $rc -eq 0 ]]; then
        log_success "[docker] ${package} for ${distro} completed"
        organize_rpm_output "${build_dir}" "${distro}" "${output_base}"
        summarize_build_output "${build_dir}"
    else
        log_error "[docker] ${package} for ${distro} FAILED (see ${log_file})"
    fi

    return $rc
}

# ─── Build DEB ─────────────────────────────────────────────────────────────

builder_docker_build_deb() {
    local package="$1"
    local distro="$2"
    local pg_major="$3"
    local pg_full="$4"
    local pg_release="$5"
    local output_base="${6:-${BUILDENV_PROJECT_ROOT}/output}"

    local full_image
    full_image=$(_docker_ensure_image "$distro") || return 1

    local build_dir
    build_dir=$(init_build_output "docker" "$distro" "$package" "$output_base")
    chmod -R a+rwX "${build_dir}"

    local log_file
    log_file=$(get_build_log "docker" "$distro" "$package" "$output_base")

    local make_jobs
    make_jobs=$(nproc 2>/dev/null || echo 4)

    local pkg_dir=""
    if [[ -d "${BUILDENV_PROJECT_ROOT}/debian/main/non-common/${package}/${distro}" ]]; then
        pkg_dir="debian/main/non-common/${package}/${distro}"
    elif [[ -d "${BUILDENV_PROJECT_ROOT}/debian/main/non-common/${package}/main" ]]; then
        pkg_dir="debian/main/non-common/${package}/main"
    elif [[ -d "${BUILDENV_PROJECT_ROOT}/debian/main/common/${package}/${distro}" ]]; then
        pkg_dir="debian/main/common/${package}/${distro}"
    elif [[ -d "${BUILDENV_PROJECT_ROOT}/debian/main/common/${package}/main" ]]; then
        pkg_dir="debian/main/common/${package}/main"
    elif [[ -d "${BUILDENV_PROJECT_ROOT}/debian/main/extras/${package}/${distro}" ]]; then
        pkg_dir="debian/main/extras/${package}/${distro}"
    elif [[ -d "${BUILDENV_PROJECT_ROOT}/debian/main/extras/${package}/main" ]]; then
        pkg_dir="debian/main/extras/${package}/main"
    else
        log_error "Package directory not found for: ${package} (distro: ${distro})"
        return 1
    fi

    local tmp_container_workdir="/tmp/build/${distro}"
    local container_workdir="/build/${pkg_dir}"

    log_build "[docker] ${package} (PG${pg_major} ${pg_full}-${pg_release}) -> ${distro}"
    log_info "Image:    ${full_image}"
    log_info "Output:   ${build_dir}"
    log_info "Log:      ${log_file}"
    log_info "Workdir:  ${container_workdir}"

    ${DOCKER_CMD} run --rm \
        -v "${BUILDENV_PROJECT_ROOT}:/build" \
        -v "${build_dir}:/output" \
        -w "${container_workdir}" \
        -e HOME=/home/builder \
        "$full_image" \
        bash -c "
            set -e
            echo '==> Preparing isolated build env'
            mkdir -p ${tmp_container_workdir}
            cd ${tmp_container_workdir}
            echo '==> Download source'
            mkdir -p src
            cd src

            if [ ! -f postgresql-${pg_full}.tar.bz2 ]; then
                wget -q https://ftp.postgresql.org/pub/source/v${pg_full}/postgresql-${pg_full}.tar.bz2 || true
            fi

            if [ -f postgresql-${pg_full}.tar.bz2 ]; then
                tar -xjf postgresql-${pg_full}.tar.bz2
            else
                echo 'WARN: no source tarball'
                mkdir postgresql-${pg_full}
            fi

            cd postgresql-${pg_full}

            echo '==> Linking debian packaging'
            mkdir -p debian

            PKG_SRC="${container_workdir}/debian"

            if [ ! -d \$PKG_SRC ]; then
                echo 'ERROR: Packaging source missing'
                exit 1
            fi

            # Remove empty dir and symlink contents
            rm -rf debian

            ln -s \$PKG_SRC debian

            echo '==> Building package'
            export DEB_BUILD_OPTIONS=\"parallel=${make_jobs}\"
            dpkg-buildpackage -us -uc -b -Pnocheck

            echo '==> Collect artifacts'
            find .. -maxdepth 2 -name '*.deb' \
                -exec cp -v {} /output/DEBS/ \; 2>/dev/null || true

            echo '==> Done'
        " 2>&1 | tee "${log_file}"

    local rc=${PIPESTATUS[0]}

    if [[ $rc -eq 0 ]]; then
        log_success "[docker] DEB ${package} for ${distro} completed"
        organize_deb_output "${build_dir}" "${distro}" "${output_base}"
        summarize_build_output "${build_dir}"
    else
        log_error "[docker] DEB ${package} for ${distro} FAILED (see ${log_file})"
    fi

    return $rc
}

# ─── Shell ─────────────────────────────────────────────────────────────────

# Open an interactive shell in a Docker build container.
# Usage: builder_docker_shell <distro>
builder_docker_shell() {
    local distro="$1"

    local full_image
    full_image=$(_docker_ensure_image "$distro") || return 1

    log_info "[docker] Opening shell in ${distro} build environment..."
    ${DOCKER_CMD} run -it --rm \
        -v "${BUILDENV_PROJECT_ROOT}:/build:z" \
        -w /build \
        -e "HOME=/home/builder" \
        "$full_image" \
        /bin/bash
}

# ─── Setup ─────────────────────────────────────────────────────────────────

# Build all Docker images.
# Usage: builder_docker_setup [--no-cache]
builder_docker_setup() {
    local no_cache=""
    [[ "${1:-}" == "--no-cache" ]] && no_cache="--no-cache"

    log_step "[docker] Building all Docker images..."

    for dockerfile in "${BUILDENV_PROJECT_ROOT}"/docker/*/Dockerfile; do
        [[ -f "$dockerfile" ]] || continue
        local dir
        dir=$(dirname "$dockerfile")
        local tag
        tag=$(basename "$dir")
        local full_image="${DOCKER_IMAGE_PREFIX}:${tag}"

        log_info "Building image: ${full_image}"
        ${DOCKER_CMD} build ${no_cache} -t "$full_image" "$dir"
    done

    log_success "[docker] All Docker images built"
}

# ─── Clean ─────────────────────────────────────────────────────────────────

# Remove Docker build images and containers.
# Usage: builder_docker_clean
builder_docker_clean() {
    log_step "[docker] Cleaning Docker resources..."

    # Remove images matching our prefix
    ${DOCKER_CMD} images --filter "reference=${DOCKER_IMAGE_PREFIX}:*" -q | \
        xargs -r ${DOCKER_CMD} rmi -f 2>/dev/null || true

    # Prune dangling images
    ${DOCKER_CMD} image prune -f 2>/dev/null || true

    log_success "[docker] Cleanup complete"
}
