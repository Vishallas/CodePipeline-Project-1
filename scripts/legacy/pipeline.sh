#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# pipeline.sh — PostgreSQL RPM build pipeline orchestrator
# ─────────────────────────────────────────────────────────────────────────────
#
# Reads pipeline.conf and builds RPM packages for all enabled PostgreSQL
# versions and target distributions using Docker.
#
# Usage:
#   ./scripts/pipeline.sh <command> [options]
#
# Commands:
#   build           Build all enabled versions for all enabled distros
#   build-all-rpm   Build ALL versions × ALL RPM distros (ignores enabled flags)
#   build-version   Build a specific PG version for all enabled distros
#   build-distro    Build all enabled versions for a specific distro
#   build-one       Build a specific PG version for a specific distro
#   status          Show current config (what would be built)
#   validate        Validate spec files and patches
#   tag             Create release tags for built versions
#   publish         Publish built RPMs to repository (S3)
#   pulp-publish    Publish built RPMs to Pulp repository
#   pulp-status     Show Pulp repository status
#   clean           Remove build artifacts
#
# Examples:
#   ./scripts/pipeline.sh build                    # Build everything enabled
#   ./scripts/pipeline.sh build-all-rpm            # Build ALL RPM combinations
#   ./scripts/pipeline.sh build-version 17         # Build PG17 for all distros
#   ./scripts/pipeline.sh build-distro EL-9        # Build all PGs for EL-9
#   ./scripts/pipeline.sh build-one 17 EL-9        # Build PG17 for EL-9 only
#   ./scripts/pipeline.sh status                   # Show what would be built
#   ./scripts/pipeline.sh validate                 # Check specs and patches
#   ./scripts/pipeline.sh tag                      # Tag current builds
#   ./scripts/pipeline.sh publish                  # Push RPMs to S3 repo
#   ./scripts/pipeline.sh pulp-publish             # Push RPMs to Pulp repo
#   ./scripts/pipeline.sh pulp-status              # Show Pulp repo status
#   ./scripts/pipeline.sh clean                    # Remove output/
#
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "${SCRIPT_DIR}")"
CONF_FILE="${REPO_ROOT}/pipeline.conf"

# ─── Colors ───────────────────────────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# ─── Logging ──────────────────────────────────────────────────────────────────

log_info()    { echo -e "${BLUE}[INFO]${NC}    $*"; }
log_success() { echo -e "${GREEN}[OK]${NC}      $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}    $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC}   $*"; }
log_step()    { echo -e "${CYAN}[STEP]${NC}    $*"; }
log_build()   { echo -e "${BOLD}[BUILD]${NC}   $*"; }

# ─── Load Configuration ──────────────────────────────────────────────────────

load_config() {
    if [ ! -f "$CONF_FILE" ]; then
        log_error "Configuration file not found: $CONF_FILE"
        exit 1
    fi
    # shellcheck source=../pipeline.conf
    source "$CONF_FILE"
}

# ─── Build Environment Integration ──────────────────────────────────────────
#
# Source the build environment abstraction layer. The BUILD_ENV variable
# from pipeline.conf (or environment) selects which builder to use.
# Supported: docker (default), mock, pbuilder, direct
#

BUILDENV_SCRIPT="${SCRIPT_DIR}/build-envs/common.sh"
if [ -f "$BUILDENV_SCRIPT" ]; then
    source "$BUILDENV_SCRIPT"
fi

# Resolve which builder to use for a given format (rpm/deb).
# Priority: RPM_BUILD_ENV/DEB_BUILD_ENV > BUILD_ENV > "docker"
_resolve_builder() {
    local format="$1"  # rpm or deb
    if [ "$format" = "rpm" ] && [ -n "${RPM_BUILD_ENV:-}" ]; then
        echo "$RPM_BUILD_ENV"
    elif [ "$format" = "deb" ] && [ -n "${DEB_BUILD_ENV:-}" ]; then
        echo "$DEB_BUILD_ENV"
    elif [ -n "${BUILD_ENV:-}" ]; then
        echo "$BUILD_ENV"
    else
        echo "docker"
    fi
}

# Load and invoke the appropriate builder driver for an RPM build.
_buildenv_build_rpm() {
    local package="$1" distro="$2" pg_major="$3" pg_full="$4" pg_release="$5"
    local builder
    builder=$(_resolve_builder "rpm")
    local driver="${SCRIPT_DIR}/build-envs/${builder}.sh"

    if [ -f "$driver" ]; then
        source "$driver"
        "builder_${builder}_build_rpm" "$package" "$distro" "$pg_major" "$pg_full" "$pg_release" "${REPO_ROOT}/${OUTPUT_DIR}"
    else
        log_error "Builder driver not found: ${driver}"
        return 1
    fi
}

# ─── Parse Version Config ────────────────────────────────────────────────────

# Parse a PG_VERSIONS entry into variables
# Usage: parse_pg_version "17:17.7:1:1"
#   Sets: _PG_MAJOR, _PG_FULL, _PG_RELEASE, _PG_ENABLED
parse_pg_version() {
    IFS=':' read -r _PG_MAJOR _PG_FULL _PG_RELEASE _PG_ENABLED <<< "$1"
}

# Parse a BUILD_TARGETS entry into variables
# Usage: parse_build_target "EL-9:el9:1"
#   Sets: _BT_DISTRO, _BT_IMAGE, _BT_ENABLED
parse_build_target() {
    IFS=':' read -r _BT_DISTRO _BT_IMAGE _BT_ENABLED <<< "$1"
}

# ─── Get enabled versions/distros ────────────────────────────────────────────

get_enabled_versions() {
    local versions=()
    for entry in "${PG_VERSIONS[@]}"; do
        parse_pg_version "$entry"
        if [ "$_PG_ENABLED" = "1" ]; then
            versions+=("$_PG_MAJOR")
        fi
    done
    echo "${versions[@]}"
}

get_enabled_distros() {
    local distros=()
    for entry in "${BUILD_TARGETS[@]}"; do
        parse_build_target "$entry"
        if [ "$_BT_ENABLED" = "1" ]; then
            distros+=("$_BT_DISTRO")
        fi
    done
    echo "${distros[@]}"
}

get_version_entry() {
    local target_major="$1"
    for entry in "${PG_VERSIONS[@]}"; do
        parse_pg_version "$entry"
        if [ "$_PG_MAJOR" = "$target_major" ]; then
            echo "$entry"
            return 0
        fi
    done
    return 1
}

get_distro_entry() {
    local target_distro="$1"
    for entry in "${BUILD_TARGETS[@]}"; do
        parse_build_target "$entry"
        if [ "$_BT_DISTRO" = "$target_distro" ]; then
            echo "$entry"
            return 0
        fi
    done
    return 1
}

# ─── Docker Helpers ───────────────────────────────────────────────────────────

ensure_docker_image() {
    local image_tag="$1"
    local full_image="${DOCKER_IMAGE_PREFIX}:${image_tag}"

    if ! docker image inspect "$full_image" &>/dev/null; then
        log_info "Building Docker image: ${full_image}"
        local dockerfile_dir="${REPO_ROOT}/docker/${image_tag}"
        if [ ! -f "${dockerfile_dir}/Dockerfile" ]; then
            log_error "Dockerfile not found: ${dockerfile_dir}/Dockerfile"
            return 1
        fi
        docker build -t "$full_image" "${dockerfile_dir}"
    fi
}

get_make_jobs() {
    if [ "${MAKE_JOBS:-0}" -eq 0 ]; then
        nproc 2>/dev/null || echo 4
    else
        echo "$MAKE_JOBS"
    fi
}

# ─── Core Build Function ─────────────────────────────────────────────────────

# Build a single PostgreSQL version for a single distribution
# Usage: build_package <pg_major> <pg_full> <pg_release> <distro_id> <docker_image>
build_package() {
    local pg_major="$1"
    local pg_full="$2"
    local pg_release="$3"
    local distro_id="$4"
    local docker_image="$5"

    local builder
    builder=$(_resolve_builder "rpm")
    local build_start build_end build_duration

    build_start=$(date +%s)

    # ── Delegate to build environment abstraction if available ──
    if [ "$builder" != "docker" ] && [ -f "${SCRIPT_DIR}/build-envs/${builder}.sh" ]; then
        log_build "PostgreSQL ${pg_major} (${pg_full}-${pg_release}pg-platform) → ${distro_id} [${builder}]"
        echo ""

        _buildenv_build_rpm "postgresql-${pg_major}" "$distro_id" "$pg_major" "$pg_full" "$pg_release"
        local rc=$?

        build_end=$(date +%s)
        build_duration=$((build_end - build_start))
        if [ $rc -eq 0 ]; then
            log_success "PostgreSQL ${pg_major} for ${distro_id} completed (${build_duration}s) [${builder}]"
        else
            log_error "PostgreSQL ${pg_major} for ${distro_id} FAILED (${build_duration}s) [${builder}]"
        fi
        echo ""
        return $rc
    fi

    # ── Default: Docker-based build (original behavior) ──

    local full_image="${DOCKER_IMAGE_PREFIX}:${docker_image}"
    local pkg_dir="rpm/redhat/main/non-common/postgresql-${pg_major}/${distro_id}"
    local out_dir="${REPO_ROOT}/${OUTPUT_DIR}/builds/docker/${distro_id}/postgresql-${pg_major}"

    # Fallback to main/ if distro directory doesn't exist
    if [ ! -d "${REPO_ROOT}/${pkg_dir}" ]; then
        pkg_dir="rpm/redhat/main/non-common/postgresql-${pg_major}/main"
    fi

    if [ ! -d "${REPO_ROOT}/${pkg_dir}" ]; then
        log_error "Package directory not found: ${pkg_dir}"
        return 1
    fi

    log_build "PostgreSQL ${pg_major} (${pg_full}-${pg_release}pg-platform) → ${distro_id} [docker]"
    echo ""

    mkdir -p "${out_dir}"/{RPMS,SRPMS}

    # Also create legacy output path for backward compatibility
    local legacy_out="${REPO_ROOT}/${OUTPUT_DIR}/${distro_id}/postgresql-${pg_major}"
    mkdir -p "${legacy_out}"/{RPMS,SRPMS}

    # Create logs directory
    mkdir -p "${REPO_ROOT}/${OUTPUT_DIR}/logs/docker/${distro_id}"

    # Run build in Docker container
    docker run --rm \
        -v "${REPO_ROOT}:/build:z" \
        -w "/build/${pkg_dir}" \
        -e "HOME=/home/builder" \
        -e "MAKEFLAGS=-j$(get_make_jobs)" \
        "$full_image" \
        bash -c '
            set -e

            SRC_DIR="$(pwd)"

            # Ensure builder home and rpmbuild directories exist
            mkdir -p /home/builder/rpm'"${pg_major}"'/{BUILD,BUILDROOT,RPMS,SRPMS}

            # Configure git safe directory
            git config --global --add safe.directory /build

            # Update spec version if needed
            SPEC_FILE=postgresql-'"${pg_major}"'.spec
            if [ -f "$SPEC_FILE" ]; then
                # Download sources
                echo "==> Downloading sources..."
                spectool -g -S \
                    --define "pgmajorversion '"${pg_major}"'" \
                    --define "pginstdir /usr/pgsql-'"${pg_major}"'" \
                    --define "pgpackageversion '"${pg_major}"'" \
                    "$SPEC_FILE" 2>&1 || true

                # Build binary RPMs
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

                # Build SRPM if configured
                if [ '"${BUILD_SRPMS}"' = "1" ]; then
                    echo "==> Building SRPM..."
                    rpmbuild \
                        --define "_sourcedir ${SRC_DIR}" \
                        --define "_specdir ${SRC_DIR}" \
                        --define "_builddir /home/builder/rpm'"${pg_major}"'/BUILD" \
                        --define "_buildrootdir /home/builder/rpm'"${pg_major}"'/BUILDROOT" \
                        --define "_srcrpmdir /home/builder/rpm'"${pg_major}"'/SRPMS" \
                        --define "pgmajorversion '"${pg_major}"'" \
                        --define "pginstdir /usr/pgsql-'"${pg_major}"'" \
                        --define "pgpackageversion '"${pg_major}"'" \
                        --define "_rpmdir /home/builder/rpm'"${pg_major}"'/RPMS/" \
                        --nodeps -bs "$SPEC_FILE"
                fi

                # Copy results to segregated output directory
                echo "==> Collecting artifacts..."
                find /home/builder/rpm'"${pg_major}"'/RPMS/ -name "*.rpm" -exec cp -v {} /build/'"${OUTPUT_DIR}"'/builds/docker/'"${distro_id}"'/postgresql-'"${pg_major}"'/RPMS/ \;
                find /home/builder/rpm'"${pg_major}"'/SRPMS/ -name "*.src.rpm" -exec cp -v {} /build/'"${OUTPUT_DIR}"'/builds/docker/'"${distro_id}"'/postgresql-'"${pg_major}"'/SRPMS/ \; 2>/dev/null || true

                # Also copy to legacy path for backward compatibility
                find /home/builder/rpm'"${pg_major}"'/RPMS/ -name "*.rpm" -exec cp -v {} /build/'"${OUTPUT_DIR}"'/'"${distro_id}"'/postgresql-'"${pg_major}"'/RPMS/ \; 2>/dev/null || true
                find /home/builder/rpm'"${pg_major}"'/SRPMS/ -name "*.src.rpm" -exec cp -v {} /build/'"${OUTPUT_DIR}"'/'"${distro_id}"'/postgresql-'"${pg_major}"'/SRPMS/ \; 2>/dev/null || true
            else
                echo "ERROR: Spec file not found"
                exit 1
            fi
        '

    local rc=$?
    build_end=$(date +%s)
    build_duration=$((build_end - build_start))

    if [ $rc -eq 0 ]; then
        log_success "PostgreSQL ${pg_major} for ${distro_id} completed (${build_duration}s) [docker]"

        # Organize into repo structure
        if [ -f "${SCRIPT_DIR}/build-envs/common.sh" ]; then
            source "${SCRIPT_DIR}/build-envs/common.sh"
            organize_rpm_output "${out_dir}" "${distro_id}" "${REPO_ROOT}/${OUTPUT_DIR}" 2>/dev/null || true
        fi

        # Run rpmlint if configured
        if [ "${RUN_RPMLINT:-0}" = "1" ]; then
            local rpm_count
            rpm_count=$(find "${out_dir}/RPMS" -name '*.rpm' 2>/dev/null | wc -l)
            if [ "$rpm_count" -gt 0 ]; then
                log_info "Running rpmlint on ${rpm_count} RPMs..."
                find "${out_dir}/RPMS" -name '*.rpm' -exec rpmlint {} \; 2>/dev/null || true
            fi
        fi
    else
        log_error "PostgreSQL ${pg_major} for ${distro_id} FAILED (${build_duration}s) [docker]"
    fi

    echo ""
    return $rc
}

# ─── Sign Packages ───────────────────────────────────────────────────────────

sign_packages() {
    if [ "${SIGN_PACKAGES:-0}" != "1" ]; then
        log_info "Package signing disabled (SIGN_PACKAGES=0)"
        return 0
    fi

    local key_id="${GPG_KEY_ID:-}"
    if [ -z "$key_id" ]; then
        log_error "GPG_KEY_ID not set. Export it or set it in pipeline.conf"
        return 1
    fi

    log_step "Signing packages with GPG key: ${key_id}"

    find "${REPO_ROOT}/${OUTPUT_DIR}" -name '*.rpm' | while read -r rpm_file; do
        log_info "Signing: $(basename "$rpm_file")"
        rpm --addsign --define "_gpg_name ${key_id}" "$rpm_file"
    done

    log_success "All packages signed"
}

# ─── Commands ─────────────────────────────────────────────────────────────────

cmd_status() {
    load_config

    echo ""
    echo "═══════════════════════════════════════════════════════════════════"
    echo "  Pipeline Configuration Status"
    echo "═══════════════════════════════════════════════════════════════════"
    echo ""

    echo "  PostgreSQL Versions:"
    echo "  ─────────────────────────────────────────────────────────────────"
    printf "  %-8s %-12s %-10s %-10s\n" "Major" "Version" "Release" "Status"
    echo "  ─────────────────────────────────────────────────────────────────"
    for entry in "${PG_VERSIONS[@]}"; do
        parse_pg_version "$entry"
        local status
        if [ "$_PG_ENABLED" = "1" ]; then
            status="${GREEN}ENABLED${NC}"
        else
            status="${DIM}disabled${NC}"
        fi
        printf "  %-8s %-12s %-10s " "$_PG_MAJOR" "$_PG_FULL" "${_PG_RELEASE}pg-platform"
        echo -e "$status"
    done
    echo ""

    echo "  Build Targets:"
    echo "  ─────────────────────────────────────────────────────────────────"
    printf "  %-12s %-20s %-10s %-10s\n" "Distro" "Docker Image" "Dockerfile" "Status"
    echo "  ─────────────────────────────────────────────────────────────────"
    for entry in "${BUILD_TARGETS[@]}"; do
        parse_build_target "$entry"
        local status dockerfile_exists
        if [ "$_BT_ENABLED" = "1" ]; then
            status="${GREEN}ENABLED${NC}"
        else
            status="${DIM}disabled${NC}"
        fi
        if [ -f "${REPO_ROOT}/docker/${_BT_IMAGE}/Dockerfile" ]; then
            dockerfile_exists="${GREEN}yes${NC}"
        else
            dockerfile_exists="${RED}missing${NC}"
        fi
        printf "  %-12s %-20s " "$_BT_DISTRO" "${DOCKER_IMAGE_PREFIX}:${_BT_IMAGE}"
        echo -ne "$dockerfile_exists"
        printf "     "
        echo -e "$status"
    done
    echo ""

    echo "  Build Matrix (what will be built):"
    echo "  ─────────────────────────────────────────────────────────────────"

    local total_builds=0
    for v_entry in "${PG_VERSIONS[@]}"; do
        parse_pg_version "$v_entry"
        [ "$_PG_ENABLED" != "1" ] && continue
        local pg_major="$_PG_MAJOR"
        local pg_full="$_PG_FULL"

        for d_entry in "${BUILD_TARGETS[@]}"; do
            parse_build_target "$d_entry"
            [ "$_BT_ENABLED" != "1" ] && continue
            echo "    PG${pg_major} (${pg_full}) × ${_BT_DISTRO}"
            total_builds=$((total_builds + 1))
        done
    done

    echo ""
    echo "  Total builds: ${total_builds}"
    echo ""

    echo "  Build Environment:"
    echo "    Builder:        ${BUILD_ENV:-docker}"
    if [ -n "${RPM_BUILD_ENV:-}" ]; then
        echo "    RPM builder:    ${RPM_BUILD_ENV}"
    fi
    if [ -n "${DEB_BUILD_ENV:-}" ]; then
        echo "    DEB builder:    ${DEB_BUILD_ENV}"
    fi
    echo ""

    echo "  Options:"
    echo "    Sign packages:  $([ "${SIGN_PACKAGES:-0}" = "1" ] && echo "yes" || echo "no")"
    echo "    Build SRPMs:    $([ "${BUILD_SRPMS:-1}" = "1" ] && echo "yes" || echo "no")"
    echo "    Run rpmlint:    $([ "${RUN_RPMLINT:-0}" = "1" ] && echo "yes" || echo "no")"
    echo "    Output dir:     ${OUTPUT_DIR}"
    echo "    Output layout:  ${OUTPUT_DIR}/builds/<builder>/<distro>/<package>/"
    echo ""
    echo "═══════════════════════════════════════════════════════════════════"
    echo ""
}

cmd_build() {
    load_config

    local failed=0
    local succeeded=0
    local skipped=0
    local pipeline_start
    pipeline_start=$(date +%s)

    echo ""
    echo "═══════════════════════════════════════════════════════════════════"
    echo "  PostgreSQL RPM Build Pipeline"
    echo "═══════════════════════════════════════════════════════════════════"
    echo ""

    for v_entry in "${PG_VERSIONS[@]}"; do
        parse_pg_version "$v_entry"
        [ "$_PG_ENABLED" != "1" ] && continue
        local pg_major="$_PG_MAJOR"
        local pg_full="$_PG_FULL"
        local pg_release="$_PG_RELEASE"

        for d_entry in "${BUILD_TARGETS[@]}"; do
            parse_build_target "$d_entry"
            [ "$_BT_ENABLED" != "1" ] && continue

            ensure_docker_image "$_BT_IMAGE" || { skipped=$((skipped + 1)); continue; }

            if build_package "$pg_major" "$pg_full" "$pg_release" "$_BT_DISTRO" "$_BT_IMAGE"; then
                succeeded=$((succeeded + 1))
            else
                failed=$((failed + 1))
            fi
        done
    done

    # Sign if configured
    sign_packages

    local pipeline_end
    pipeline_end=$(date +%s)
    local pipeline_duration=$((pipeline_end - pipeline_start))

    echo ""
    echo "═══════════════════════════════════════════════════════════════════"
    echo "  Pipeline Complete"
    echo "═══════════════════════════════════════════════════════════════════"
    echo ""
    echo "  Succeeded: ${succeeded}"
    echo "  Failed:    ${failed}"
    echo "  Skipped:   ${skipped}"
    echo "  Duration:  ${pipeline_duration}s"
    echo ""

    if [ "$failed" -gt 0 ]; then
        log_error "${failed} build(s) failed"
        return 1
    fi
}

cmd_build_version() {
    local target_ver="${1:-}"
    if [ -z "$target_ver" ]; then
        log_error "Usage: pipeline.sh build-version <pg_major_version>"
        echo "  Example: pipeline.sh build-version 17"
        exit 1
    fi

    load_config

    local v_entry
    v_entry=$(get_version_entry "$target_ver") || {
        log_error "Version PG${target_ver} not found in pipeline.conf"
        exit 1
    }
    parse_pg_version "$v_entry"
    local pg_major="$_PG_MAJOR" pg_full="$_PG_FULL" pg_release="$_PG_RELEASE"

    echo ""
    log_build "Building PostgreSQL ${pg_major} (${pg_full}) for all enabled distros"
    echo ""

    local failed=0
    for d_entry in "${BUILD_TARGETS[@]}"; do
        parse_build_target "$d_entry"
        [ "$_BT_ENABLED" != "1" ] && continue
        ensure_docker_image "$_BT_IMAGE" || continue
        build_package "$pg_major" "$pg_full" "$pg_release" "$_BT_DISTRO" "$_BT_IMAGE" || failed=$((failed + 1))
    done

    sign_packages
    [ "$failed" -gt 0 ] && return 1 || return 0
}

cmd_build_distro() {
    local target_distro="${1:-}"
    if [ -z "$target_distro" ]; then
        log_error "Usage: pipeline.sh build-distro <distro_id>"
        echo "  Example: pipeline.sh build-distro EL-9"
        exit 1
    fi

    load_config

    local d_entry
    d_entry=$(get_distro_entry "$target_distro") || {
        log_error "Distribution ${target_distro} not found in pipeline.conf"
        exit 1
    }
    parse_build_target "$d_entry"
    local distro_id="$_BT_DISTRO" docker_image="$_BT_IMAGE"

    echo ""
    log_build "Building all enabled versions for ${distro_id}"
    echo ""

    ensure_docker_image "$docker_image" || exit 1

    local failed=0
    for v_entry in "${PG_VERSIONS[@]}"; do
        parse_pg_version "$v_entry"
        [ "$_PG_ENABLED" != "1" ] && continue
        build_package "$_PG_MAJOR" "$_PG_FULL" "$_PG_RELEASE" "$distro_id" "$docker_image" || failed=$((failed + 1))
    done

    sign_packages
    [ "$failed" -gt 0 ] && return 1 || return 0
}

cmd_build_one() {
    local target_ver="${1:-}"
    local target_distro="${2:-}"

    if [ -z "$target_ver" ] || [ -z "$target_distro" ]; then
        log_error "Usage: pipeline.sh build-one <pg_major_version> <distro_id>"
        echo "  Example: pipeline.sh build-one 17 EL-9"
        exit 1
    fi

    load_config

    local v_entry d_entry
    v_entry=$(get_version_entry "$target_ver") || { log_error "Version PG${target_ver} not found"; exit 1; }
    d_entry=$(get_distro_entry "$target_distro") || { log_error "Distro ${target_distro} not found"; exit 1; }

    parse_pg_version "$v_entry"
    local pg_major="$_PG_MAJOR" pg_full="$_PG_FULL" pg_release="$_PG_RELEASE"

    parse_build_target "$d_entry"
    local distro_id="$_BT_DISTRO" docker_image="$_BT_IMAGE"

    ensure_docker_image "$docker_image" || exit 1
    build_package "$pg_major" "$pg_full" "$pg_release" "$distro_id" "$docker_image"
}

cmd_build_all_rpm() {
    load_config

    local failed=0
    local succeeded=0
    local skipped=0
    local pipeline_start
    pipeline_start=$(date +%s)

    echo ""
    echo "═══════════════════════════════════════════════════════════════════"
    echo "  PostgreSQL RPM Build Pipeline — ALL RPM Combinations"
    echo "═══════════════════════════════════════════════════════════════════"
    echo ""

    # Build ALL PG versions × ALL RPM distros, ignoring ENABLED flags
    for v_entry in "${PG_VERSIONS[@]}"; do
        parse_pg_version "$v_entry"
        local pg_major="$_PG_MAJOR"
        local pg_full="$_PG_FULL"
        local pg_release="$_PG_RELEASE"

        for d_entry in "${BUILD_TARGETS[@]}"; do
            parse_build_target "$d_entry"

            ensure_docker_image "$_BT_IMAGE" || { skipped=$((skipped + 1)); continue; }

            if build_package "$pg_major" "$pg_full" "$pg_release" "$_BT_DISTRO" "$_BT_IMAGE"; then
                succeeded=$((succeeded + 1))
            else
                failed=$((failed + 1))
            fi
        done
    done

    # Sign if configured
    sign_packages

    local pipeline_end
    pipeline_end=$(date +%s)
    local pipeline_duration=$((pipeline_end - pipeline_start))

    echo ""
    echo "═══════════════════════════════════════════════════════════════════"
    echo "  Pipeline Complete — ALL RPM Combinations"
    echo "═══════════════════════════════════════════════════════════════════"
    echo ""
    echo "  Succeeded: ${succeeded}"
    echo "  Failed:    ${failed}"
    echo "  Skipped:   ${skipped}"
    echo "  Duration:  ${pipeline_duration}s"
    echo "  Total:     $((succeeded + failed + skipped)) (${#PG_VERSIONS[@]} versions × ${#BUILD_TARGETS[@]} distros)"
    echo ""

    if [ "$failed" -gt 0 ]; then
        log_error "${failed} build(s) failed"
        return 1
    fi
}

cmd_validate() {
    load_config

    echo ""
    echo "═══════════════════════════════════════════════════════════════════"
    echo "  Validating Packaging Files"
    echo "═══════════════════════════════════════════════════════════════════"
    echo ""

    local errors=0

    for v_entry in "${PG_VERSIONS[@]}"; do
        parse_pg_version "$v_entry"
        [ "$_PG_ENABLED" != "1" ] && continue
        local pg_major="$_PG_MAJOR"
        local pkg_dir="${REPO_ROOT}/rpm/redhat/main/non-common/postgresql-${pg_major}/main"

        log_step "Validating PostgreSQL ${pg_major}..."

        # Check spec file exists
        local spec="${pkg_dir}/postgresql-${pg_major}.spec"
        if [ -f "$spec" ]; then
            log_success "Spec file exists"

            # Validate with rpmbuild --parse if available
            if command -v rpmbuild &>/dev/null; then
                if rpmbuild --define "pgmajorversion ${pg_major}" \
                            --define "pginstdir /usr/pgsql-${pg_major}" \
                            --define "pgpackageversion ${pg_major}" \
                            --nobuild --nodeps "$spec" &>/dev/null; then
                    log_success "Spec file parses correctly"
                else
                    log_warn "Spec file parse issues (may need build deps)"
                fi
            fi
        else
            log_error "Spec file missing: ${spec}"
            errors=$((errors + 1))
        fi

        # Check required supporting files
        for required_file in \
            "postgresql-${pg_major}-setup" \
            "postgresql-${pg_major}-check-db-dir" \
            "postgresql-${pg_major}.service" \
            "postgresql-${pg_major}.pam" \
            "postgresql-${pg_major}-tmpfiles.d" \
            "postgresql-${pg_major}-sysusers.conf" \
            "postgresql-${pg_major}-libs.conf" \
            "postgresql-${pg_major}-pg_config.h" \
            "postgresql-${pg_major}-ecpg_config.h" \
            "postgresql-${pg_major}-Makefile.regress" \
            "Makefile"; do

            if [ -f "${pkg_dir}/${required_file}" ]; then
                log_success "  ${required_file}"
            else
                log_error "  Missing: ${required_file}"
                errors=$((errors + 1))
            fi
        done

        # Check patches
        local patch_count
        patch_count=$(find "${pkg_dir}" -name "*.patch" 2>/dev/null | wc -l)
        if [ "$patch_count" -ge 3 ]; then
            log_success "  ${patch_count} patches found"
        else
            log_warn "  Only ${patch_count} patches (expected >= 3)"
        fi

        # Check distribution symlinks
        for d_entry in "${BUILD_TARGETS[@]}"; do
            parse_build_target "$d_entry"
            local distro_dir="${REPO_ROOT}/rpm/redhat/main/non-common/postgresql-${pg_major}/${_BT_DISTRO}"
            if [ -d "$distro_dir" ]; then
                local symlink_count
                symlink_count=$(find "$distro_dir" -type l 2>/dev/null | wc -l)
                if [ "$symlink_count" -gt 0 ]; then
                    log_success "  ${_BT_DISTRO}: ${symlink_count} symlinks"
                else
                    log_warn "  ${_BT_DISTRO}: no symlinks (using main/ directly)"
                fi
            fi
        done

        # Check global Makefile target
        if [ -f "${REPO_ROOT}/rpm/redhat/global/Makefile.global-PG${pg_major}" ]; then
            log_success "  Global Makefile target exists"
        else
            log_error "  Global Makefile target missing"
            errors=$((errors + 1))
        fi

        echo ""
    done

    if [ "$errors" -gt 0 ]; then
        log_error "Validation found ${errors} error(s)"
        return 1
    else
        log_success "All validations passed"
    fi
}

cmd_tag() {
    load_config

    echo ""
    log_step "Creating release tags..."
    echo ""

    local current_branch
    current_branch=$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD)

    if [ "$current_branch" != "main" ] && [[ "$current_branch" != release/* ]]; then
        log_warn "Current branch is '${current_branch}'"
        log_warn "Release tags should be created from 'main' or 'release/*' branches"
        read -rp "Continue anyway? [y/N] " confirm
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            echo "Aborted."
            return 0
        fi
    fi

    for v_entry in "${PG_VERSIONS[@]}"; do
        parse_pg_version "$v_entry"
        [ "$_PG_ENABLED" != "1" ] && continue

        local tag_name="v${_PG_FULL}-${_PG_RELEASE}pg-platform"

        if git -C "$REPO_ROOT" tag -l "$tag_name" | grep -q "$tag_name"; then
            log_warn "Tag already exists: ${tag_name}"
        else
            git -C "$REPO_ROOT" tag -a "$tag_name" \
                -m "Release PostgreSQL ${_PG_FULL}-${_PG_RELEASE}pg-platform"
            log_success "Created tag: ${tag_name}"
        fi
    done

    echo ""
    log_info "Push tags with: git push origin --tags"
}

cmd_publish() {
    load_config

    local bucket="${S3_BUCKET:-}"
    if [ -z "$bucket" ]; then
        log_error "S3_BUCKET not configured in pipeline.conf"
        return 1
    fi

    echo ""
    log_step "Publishing RPMs to s3://${bucket}/"
    echo ""

    for d_entry in "${BUILD_TARGETS[@]}"; do
        parse_build_target "$d_entry"
        [ "$_BT_ENABLED" != "1" ] && continue

        local distro_out="${REPO_ROOT}/${OUTPUT_DIR}/${_BT_DISTRO}"
        if [ ! -d "$distro_out" ]; then
            log_warn "No output for ${_BT_DISTRO}, skipping"
            continue
        fi

        log_info "Syncing ${_BT_DISTRO} to S3..."

        # Create repo metadata
        if command -v createrepo_c &>/dev/null; then
            createrepo_c --update "${distro_out}" 2>/dev/null || true
        fi

        # Sync to S3
        aws s3 sync "${distro_out}/" "s3://${bucket}/${_BT_DISTRO}/" \
            --delete \
            --exclude ".repodata/*"

        log_success "Published ${_BT_DISTRO}"
    done

    # Invalidate CloudFront if configured
    local cf_dist="${CLOUDFRONT_DIST_ID:-}"
    if [ -n "$cf_dist" ]; then
        log_info "Invalidating CloudFront cache..."
        aws cloudfront create-invalidation \
            --distribution-id "$cf_dist" \
            --paths "/*" >/dev/null
        log_success "CloudFront invalidation triggered"
    fi

    echo ""
    log_success "Publish complete"
}

cmd_pulp_publish() {
    load_config

    local pulp_manager="${SCRIPT_DIR}/pulp-repo-manager.sh"
    if [ ! -f "$pulp_manager" ]; then
        log_error "Pulp repo manager not found: ${pulp_manager}"
        return 1
    fi

    # Delegate to pulp-repo-manager.sh full-publish
    bash "$pulp_manager" full-publish "${2:-}" "${3:-}"
}

cmd_pulp_status() {
    load_config

    local pulp_manager="${SCRIPT_DIR}/pulp-repo-manager.sh"
    if [ ! -f "$pulp_manager" ]; then
        log_error "Pulp repo manager not found: ${pulp_manager}"
        return 1
    fi

    bash "$pulp_manager" status
}

cmd_clean() {
    load_config

    echo ""
    log_step "Cleaning build artifacts..."

    local out="${REPO_ROOT}/${OUTPUT_DIR}"
    if [ -d "$out" ]; then
        rm -rf "$out"
        log_success "Removed ${out}"
    else
        log_info "Nothing to clean"
    fi
    echo ""
}

# ─── Usage ────────────────────────────────────────────────────────────────────

usage() {
    cat <<'EOF'
PostgreSQL RPM Build Pipeline

Usage: pipeline.sh <command> [options]

Commands:
  status                    Show current pipeline configuration
  build                     Build all enabled versions × all enabled distros
  build-all-rpm             Build ALL versions × ALL RPM distros (ignores enabled flags)
  build-version <VER>       Build specific PG version for all enabled distros
  build-distro  <DISTRO>    Build all enabled versions for specific distro
  build-one <VER> <DISTRO>  Build specific PG version for specific distro
  validate                  Validate spec files, patches, and symlinks
  tag                       Create git release tags for enabled versions
  publish                   Publish RPMs to S3 repository
  pulp-publish [PG] [DIST]  Publish RPMs to Pulp repository
  pulp-status               Show Pulp repository status
  clean                     Remove build output directory

Examples:
  pipeline.sh status                 # What would be built?
  pipeline.sh build                  # Build everything enabled
  pipeline.sh build-all-rpm          # Build ALL RPM combinations
  pipeline.sh build-version 17      # Build PG17 for all distros
  pipeline.sh build-distro EL-9     # Build all PGs for EL-9
  pipeline.sh build-one 17 EL-9     # Build PG17 for EL-9 only
  pipeline.sh validate              # Pre-flight checks
  pipeline.sh tag                   # Tag releases
  pipeline.sh publish               # Push to S3
  pipeline.sh pulp-publish          # Push to Pulp
  pipeline.sh pulp-status           # Show Pulp repo status

Configuration:
  Edit pipeline.conf to control versions, distros, and options.
  See docs/PIPELINE_GUIDE.md for full documentation.
EOF
}

# ─── Main ─────────────────────────────────────────────────────────────────────

case "${1:-}" in
    status)          cmd_status ;;
    build)           cmd_build ;;
    build-all-rpm)   cmd_build_all_rpm ;;
    build-version)   cmd_build_version "${2:-}" ;;
    build-distro)    cmd_build_distro "${2:-}" ;;
    build-one)       cmd_build_one "${2:-}" "${3:-}" ;;
    validate)        cmd_validate ;;
    tag)             cmd_tag ;;
    publish)         cmd_publish ;;
    pulp-publish)    cmd_pulp_publish "$@" ;;
    pulp-status)     cmd_pulp_status ;;
    clean)           cmd_clean ;;
    -h|--help|help)  usage ;;
    *)
        if [ -n "${1:-}" ]; then
            log_error "Unknown command: $1"
            echo ""
        fi
        usage
        exit 1
        ;;
esac
