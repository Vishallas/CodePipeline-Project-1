#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# build-env.sh — Pg-platform PostgreSQL Platform — Build & Test Orchestrator
# ─────────────────────────────────────────────────────────────────────────────
#
# Single entry point for building and testing Pg-platform PostgreSQL packages
# across RPM (EL-8, EL-9, EL-10, Fedora) and DEB (bookworm, bullseye, jammy,
# noble, focal) distributions using pluggable build environments.
#
# Supported build environments:
#   docker        — Docker containers (default, most isolated)
#   docker-sbuild — Docker + sbuild + mmdebstrap (isolated DEB builds)
#   mmdebstrap    — mmdebstrap + sbuild (fast DEB builds, 5–10× Docker)
#   sbuild        — Traditional sbuild + debootstrap
#   mock          — Mock chroot (Fedora/EPEL standard for RPMs)
#   pbuilder      — pbuilder/cowbuilder (Debian/Ubuntu chroot)
#   direct        — Local host (no isolation, fastest)
#
# The build environment can be selected via:
#   1. Command-line flag:    --builder=mock
#   2. Environment variable: BUILD_ENV=mock
#   3. pipeline.conf:        BUILD_ENV="mock"
#   4. Default:              docker
#
# Build output is segregated by builder, distro, and package:
#
#   output/
#   ├── builds/<builder>/<distro>/<package>/{RPMS,SRPMS,DEBS}
#   ├── repos/{rpm,deb}/<distro>/...
#   └── logs/<builder>/<distro>/<package>-<timestamp>.log
#
# Usage:
#   ./scripts/build-env.sh <command> [options]
#
# Build Commands:
#   build-rpm     Build a single RPM package
#   build-deb     Build a single DEB package
#   build-all-rpm Build full RPM matrix from pipeline.conf (filterable)
#   build-all-deb Build full DEB matrix from pipeline.conf (filterable)
#
# Environment Commands:
#   check         Verify build environment prerequisites
#   setup         Initialize build environment (images/chroots)
#   shell         Open interactive shell in build environment
#   clean         Clean build environment resources
#   list-builders List available build environments and their status
#   status        Show current configuration and output layout
#
# Test Commands (integrated local build & test):
#   test-env      Validate Docker image and build tool availability per distro
#   test-install  Full cycle: build from source → install → init → health → SQL
#   test-quick    Quick Dockerfile-only validation (no env tests)
#   test-sql      Run SQL test suite against a running PostgreSQL instance
#
# ─── RPM Build Examples ───────────────────────────────────────────────────
#
#   # Build postgresql-17 RPM for EL-9 with Docker (default)
#   ./scripts/build-env.sh build-rpm \
#       --package postgresql-17 --distro EL-9 \
#       --pg-major 17 --pg-full 17.7 --pg-release 1
#
#   # Build postgresql-16 RPM for EL-8 with Mock
#   ./scripts/build-env.sh build-rpm --builder mock \
#       --package postgresql-16 --distro EL-8 \
#       --pg-major 16 --pg-full 16.6 --pg-release 1
#
#   # Build ALL RPM combinations from pipeline.conf
#   ./scripts/build-env.sh build-all-rpm
#
#   # Build PG17 across all RPM distros (EL-8, EL-9, EL-10, Fedora)
#   ./scripts/build-env.sh build-all-rpm --pg-major 17
#
#   # Build all PG versions for EL-9 only
#   ./scripts/build-env.sh build-all-rpm --distro EL-9
#
#   # Build PG17 × EL-9 only, stop on first error
#   ./scripts/build-env.sh build-all-rpm \
#       --pg-major 17 --distro EL-9 --stop-on-error
#
# ─── DEB Build Examples ───────────────────────────────────────────────────
#
#   # Build postgresql-17 DEB for Debian bookworm
#   ./scripts/build-env.sh build-deb \
#       --package postgresql-17 --distro bookworm \
#       --pg-major 17 --pg-full 17.7 --pg-release 1
#
#   # Build DEB with pbuilder (cowbuilder chroot)
#   ./scripts/build-env.sh build-deb --builder pbuilder \
#       --package postgresql-16 --distro bookworm \
#       --pg-major 16 --pg-full 16.6 --pg-release 1
#
#   # Build DEB with sbuild (standard Debian approach)
#   ./scripts/build-env.sh build-deb --builder sbuild \
#       --package postgresql-17 --distro noble \
#       --pg-major 17 --pg-full 17.7 --pg-release 1
#
#   # Build DEB with sbuild inside Docker (isolated)
#   ./scripts/build-env.sh build-deb --builder docker-sbuild \
#       --package postgresql-17 --distro jammy \
#       --pg-major 17 --pg-full 17.7 --pg-release 1
#
#   # Build ALL DEB combinations from pipeline.conf
#   ./scripts/build-env.sh build-all-deb
#
#   # Build PG16 DEBs across all Debian/Ubuntu distros
#   ./scripts/build-env.sh build-all-deb --pg-major 16
#
#   # Build all PG versions for Ubuntu Noble only
#   ./scripts/build-env.sh build-all-deb --distro noble
#
# ─── Environment & Shell Examples ─────────────────────────────────────────
#
#   # Check if Docker build environment is ready
#   ./scripts/build-env.sh check
#
#   # Check if Mock is properly configured
#   ./scripts/build-env.sh check --builder mock
#
#   # Open interactive shell in EL-9 Docker container
#   ./scripts/build-env.sh shell --distro EL-9
#
#   # Open interactive shell in bookworm pbuilder chroot
#   ./scripts/build-env.sh shell --builder pbuilder --distro bookworm
#
#   # List all available builders and their status on this system
#   ./scripts/build-env.sh list-builders
#
# ─── Test Examples ────────────────────────────────────────────────────────
#
#   # Validate build environments for all distros
#   ./scripts/build-env.sh test-env
#
#   # Validate build environment for EL-9 only
#   ./scripts/build-env.sh test-env --distro el9
#
#   # Quick Dockerfile validation (no environment checks)
#   ./scripts/build-env.sh test-quick --distro rpm
#
#   # Full install + SQL test: build PG17 from source on EL-9
#   ./scripts/build-env.sh test-install --distro el9 --pg-major 17
#
#   # Run only build and install phases (skip SQL tests)
#   ./scripts/build-env.sh test-install --distro el9 --phase build,install
#
#   # Install from pre-built RPMs, run all checks
#   ./scripts/build-env.sh test-install --distro el9 \
#       --pkg-dir ./output/builds/docker/EL-9/postgresql-17/RPMS
#
#   # Run SQL tests with a specific filter
#   ./scripts/build-env.sh test-install \
#       --distro debian-bookworm --filter "01_*"
#
#   # Run only core category SQL tests
#   ./scripts/build-env.sh test-install --distro el9 --category core
#
#   # Dry run: show what test-install would do
#   ./scripts/build-env.sh test-install --distro el9 --dry-run
#
#   # Run SQL tests standalone against an already-running PostgreSQL
#   ./scripts/build-env.sh test-sql --pg-host localhost --pg-port 5432
#
#   # List all available SQL tests
#   ./scripts/build-env.sh test-sql --sql-list
#
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "${SCRIPT_DIR}")"

# Source common utilities
source "${SCRIPT_DIR}/build-envs/common.sh"

# ─── Defaults ──────────────────────────────────────────────────────────────

DEFAULT_BUILDER="docker"
DEFAULT_OUTPUT_DIR="${PROJECT_ROOT}/output"

# Try to read BUILD_ENV from pipeline.conf
if [[ -f "${PROJECT_ROOT}/pipeline.conf" ]]; then
    # Extract BUILD_ENV without sourcing entire file (avoid side effects)
    _conf_build_env=$(grep -E '^BUILD_ENV=' "${PROJECT_ROOT}/pipeline.conf" 2>/dev/null | tail -1 | cut -d= -f2 | tr -d '"' | tr -d "'" | xargs)
    if [[ -n "${_conf_build_env:-}" ]]; then
        DEFAULT_BUILDER="${_conf_build_env}"
    fi
fi

# Environment variable override
BUILDER="${BUILD_ENV:-${DEFAULT_BUILDER}}"
OUTPUT_BASE="${BUILD_OUTPUT_DIR:-${DEFAULT_OUTPUT_DIR}}"

# ─── Parse Arguments ──────────────────────────────────────────────────────

COMMAND=""
ARG_BUILDER=""
ARG_PACKAGE=""
ARG_DISTRO=""
ARG_PG_MAJOR=""
ARG_PG_FULL=""
ARG_PG_RELEASE=""
ARG_OUTPUT=""
ARG_NO_CACHE=""
ARG_STOP_ON_ERROR=""

# ─── Test-specific arguments ──────────────────────────────────────────────
ARG_PHASE=""                # Comma-separated phases: env,build,install,init,check,sql
ARG_FILTER=""               # SQL test filter pattern (e.g., "01_*")
ARG_CATEGORY=""             # SQL test category (core, extensions, performance)
ARG_PKG_DIR=""              # Pre-built packages directory (skip build phase)
ARG_PKG_TYPE=""             # Package type override: rpm or deb
ARG_KEEP=""                 # Keep test containers after completion
ARG_NO_CLEANUP=""           # Don't clean up test images
ARG_SQL_STOP_ON_FAILURE=""  # Stop at first SQL test failure
ARG_SQL_LIST=""             # List available SQL tests
ARG_DRY_RUN=""              # Show what would be done without executing
ARG_PG_HOST=""              # PostgreSQL host for test-sql
ARG_PG_PORT=""              # PostgreSQL port for test-sql
ARG_PG_USER=""              # PostgreSQL user for test-sql
ARG_PG_DBNAME=""            # PostgreSQL database for test-sql

parse_args() {
    COMMAND="${1:-}"
    shift || true

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --builder=*)    ARG_BUILDER="${1#*=}"; shift ;;
            --builder)      ARG_BUILDER="$2"; shift 2 ;;
            --package=*)    ARG_PACKAGE="${1#*=}"; shift ;;
            --package)      ARG_PACKAGE="$2"; shift 2 ;;
            --distro=*)     ARG_DISTRO="${1#*=}"; shift ;;
            --distro)       ARG_DISTRO="$2"; shift 2 ;;
            --pg-major=*)   ARG_PG_MAJOR="${1#*=}"; shift ;;
            --pg-major)     ARG_PG_MAJOR="$2"; shift 2 ;;
            --pg-full=*)    ARG_PG_FULL="${1#*=}"; shift ;;
            --pg-full)      ARG_PG_FULL="$2"; shift 2 ;;
            --pg-release=*) ARG_PG_RELEASE="${1#*=}"; shift ;;
            --pg-release)   ARG_PG_RELEASE="$2"; shift 2 ;;
            --output=*)     ARG_OUTPUT="${1#*=}"; shift ;;
            --output)       ARG_OUTPUT="$2"; shift 2 ;;
            --no-cache)     ARG_NO_CACHE="--no-cache"; shift ;;
            --stop-on-error) ARG_STOP_ON_ERROR="1"; shift ;;
            # ── Test-specific flags ──────────────────────────────────
            --phase=*)      ARG_PHASE="${1#*=}"; shift ;;
            --phase)        ARG_PHASE="$2"; shift 2 ;;
            --filter=*)     ARG_FILTER="${1#*=}"; shift ;;
            --filter)       ARG_FILTER="$2"; shift 2 ;;
            --category=*)   ARG_CATEGORY="${1#*=}"; shift ;;
            --category)     ARG_CATEGORY="$2"; shift 2 ;;
            --pkg-dir=*)    ARG_PKG_DIR="${1#*=}"; shift ;;
            --pkg-dir)      ARG_PKG_DIR="$2"; shift 2 ;;
            --pkg-type=*)   ARG_PKG_TYPE="${1#*=}"; shift ;;
            --pkg-type)     ARG_PKG_TYPE="$2"; shift 2 ;;
            --keep)         ARG_KEEP="1"; shift ;;
            --no-cleanup)   ARG_NO_CLEANUP="1"; shift ;;
            --sql-stop-on-failure) ARG_SQL_STOP_ON_FAILURE="1"; shift ;;
            --sql-list)     ARG_SQL_LIST="1"; shift ;;
            --dry-run)      ARG_DRY_RUN="1"; shift ;;
            --pg-host=*)    ARG_PG_HOST="${1#*=}"; shift ;;
            --pg-host)      ARG_PG_HOST="$2"; shift 2 ;;
            --pg-port=*)    ARG_PG_PORT="${1#*=}"; shift ;;
            --pg-port)      ARG_PG_PORT="$2"; shift 2 ;;
            --pg-user=*)    ARG_PG_USER="${1#*=}"; shift ;;
            --pg-user)      ARG_PG_USER="$2"; shift 2 ;;
            --pg-dbname=*)  ARG_PG_DBNAME="${1#*=}"; shift ;;
            --pg-dbname)    ARG_PG_DBNAME="$2"; shift 2 ;;
            -h|--help)      usage; exit 0 ;;
            *)
                log_error "Unknown option: $1"
                usage
                exit 1
                ;;
        esac
    done

    # Apply overrides
    if [[ -n "$ARG_BUILDER" ]]; then
        BUILDER="$ARG_BUILDER"
    fi
    if [[ -n "$ARG_OUTPUT" ]]; then
        OUTPUT_BASE="$ARG_OUTPUT"
    fi
}

# ─── Load Builder Driver ──────────────────────────────────────────────────

load_builder() {
    local builder="$1"
    validate_builder "$builder" || exit 1

    local driver_file="${SCRIPT_DIR}/build-envs/${builder}.sh"
    if [[ ! -f "$driver_file" ]]; then
        log_error "Builder driver not found: ${driver_file}"
        exit 1
    fi

    source "$driver_file"
}

# ─── Commands ──────────────────────────────────────────────────────────────

cmd_build_rpm() {
    if [[ -z "$ARG_PACKAGE" ]] || [[ -z "$ARG_DISTRO" ]] || [[ -z "$ARG_PG_MAJOR" ]]; then
        log_error "Required: --package, --distro, --pg-major"
        log_error "Optional: --pg-full, --pg-release"
        echo ""
        echo "Example:"
        echo "  $0 build-rpm --package postgresql-17 --distro EL-9 --pg-major 17 --pg-full 17.7 --pg-release 1"
        exit 1
    fi

    local pg_full="${ARG_PG_FULL:-${ARG_PG_MAJOR}.0}"
    local pg_release="${ARG_PG_RELEASE:-1}"

    load_builder "$BUILDER"

    log_info "Build environment: ${BUILDER}"
    log_info "Package:           ${ARG_PACKAGE}"
    log_info "Distribution:      ${ARG_DISTRO}"
    log_info "PostgreSQL:        ${ARG_PG_MAJOR} (${pg_full}-${pg_release})"
    log_info "Output:            ${OUTPUT_BASE}"
    echo ""

    local builder_fn="builder_$(get_builder_function_prefix "${BUILDER}")_build_rpm"
    "$builder_fn" \
        "$ARG_PACKAGE" "$ARG_DISTRO" "$ARG_PG_MAJOR" "$pg_full" "$pg_release" "$OUTPUT_BASE"
}

cmd_build_deb() {
    if [[ -z "$ARG_PACKAGE" ]] || [[ -z "$ARG_DISTRO" ]] || [[ -z "$ARG_PG_MAJOR" ]]; then
        log_error "Required: --package, --distro, --pg-major"
        log_error "Optional: --pg-full, --pg-release"
        echo ""
        echo "Example:"
        echo "  $0 build-deb --package postgresql-17 --distro bookworm --pg-major 17 --pg-full 17.7 --pg-release 1"
        exit 1
    fi

    local pg_full="${ARG_PG_FULL:-${ARG_PG_MAJOR}.0}"
    local pg_release="${ARG_PG_RELEASE:-1}"

    load_builder "$BUILDER"

    log_info "Build environment: ${BUILDER}"
    log_info "Package:           ${ARG_PACKAGE}"
    log_info "Distribution:      ${ARG_DISTRO}"
    log_info "PostgreSQL:        ${ARG_PG_MAJOR} (${pg_full}-${pg_release})"
    log_info "Output:            ${OUTPUT_BASE}"
    echo ""

    local builder_fn="builder_$(get_builder_function_prefix "${BUILDER}")_build_deb"
    "$builder_fn" \
        "$ARG_PACKAGE" "$ARG_DISTRO" "$ARG_PG_MAJOR" "$pg_full" "$pg_release" "$OUTPUT_BASE"
}

# ─── Build RPM Matrix (sequential) ───────────────────────────────────────
#
# Reads pipeline.conf for PG_VERSIONS and BUILD_TARGETS, then builds
# the requested combinations one-by-one in strict sequential order.
#
# Each build must finish before the next one starts — there is no
# parallel execution. The order is: for each PG version, iterate
# through every distro before moving to the next PG version.
#
# Optional filters (narrow the matrix):
#   --pg-major 17      Only build PG 17 (across all distros)
#   --distro EL-9      Only build for EL-9 (across all PG versions)
#   both together       Build a single combination (PG17 × EL-9)
#   neither             Build ALL versions × ALL distros
#
# Flow control:
#   --stop-on-error     Stop the sequence immediately on first failure
#                       (default: continue and report failures at the end)
#

cmd_build_all_rpm() {
    local conf_file="${PROJECT_ROOT}/pipeline.conf"
    if [[ ! -f "$conf_file" ]]; then
        log_error "pipeline.conf not found at: ${conf_file}"
        exit 1
    fi

    # Source pipeline.conf to get PG_VERSIONS and BUILD_TARGETS
    source "$conf_file"

    load_builder "$BUILDER"

    local stop_on_error="${ARG_STOP_ON_ERROR:-}"

    # ── Apply filters ────────────────────────────────────────────────────
    local filter_pg="${ARG_PG_MAJOR:-}"
    local filter_distro="${ARG_DISTRO:-}"

    # Build filtered lists
    local -a filtered_versions=()
    local -a filtered_targets=()

    for v_entry in "${PG_VERSIONS[@]}"; do
        local _maj
        IFS=':' read -r _maj _ _ _ <<< "$v_entry"
        if [[ -z "$filter_pg" ]] || [[ "$_maj" == "$filter_pg" ]]; then
            filtered_versions+=("$v_entry")
        fi
    done

    for d_entry in "${BUILD_TARGETS[@]}"; do
        local _dist
        IFS=':' read -r _dist _ _ <<< "$d_entry"
        if [[ -z "$filter_distro" ]] || [[ "$_dist" == "$filter_distro" ]]; then
            filtered_targets+=("$d_entry")
        fi
    done

    # Validate filters matched something
    if [[ ${#filtered_versions[@]} -eq 0 ]]; then
        log_error "No PG version matched '${filter_pg}'"
        log_info "Available versions: $(printf '%s ' "${PG_VERSIONS[@]}" | sed 's/:[^ ]* */ /g')"
        exit 1
    fi
    if [[ ${#filtered_targets[@]} -eq 0 ]]; then
        log_error "No distro matched '${filter_distro}'"
        log_info "Available distros: $(printf '%s ' "${BUILD_TARGETS[@]}" | sed 's/:[^ ]* */ /g')"
        exit 1
    fi

    # ── Summary ──────────────────────────────────────────────────────────
    local total=$(( ${#filtered_versions[@]} * ${#filtered_targets[@]} ))
    local failed=0
    local succeeded=0
    local -a failed_list=()
    local build_start
    build_start=$(date +%s)

    # Build a readable scope label
    local scope="ALL"
    if [[ -n "$filter_pg" ]] && [[ -n "$filter_distro" ]]; then
        scope="PG${filter_pg} × ${filter_distro}"
    elif [[ -n "$filter_pg" ]]; then
        scope="PG${filter_pg} × all distros"
    elif [[ -n "$filter_distro" ]]; then
        scope="all versions × ${filter_distro}"
    fi

    echo ""
    echo "═══════════════════════════════════════════════════════════════════"
    echo "  build-env.sh — RPM Build Matrix [${BUILDER}]"
    echo "═══════════════════════════════════════════════════════════════════"
    echo ""
    echo "  Scope:          ${scope}"
    echo "  Builder:        ${BUILDER}"
    echo "  PG versions:    ${#filtered_versions[@]} of ${#PG_VERSIONS[@]}"
    echo "  RPM distros:    ${#filtered_targets[@]} of ${#BUILD_TARGETS[@]}"
    echo "  Total builds:   ${total}"
    echo "  Execution:      sequential (one at a time)"
    echo "  Stop on error:  $([ -n "$stop_on_error" ] && echo "yes" || echo "no")"
    echo "  Output:         ${OUTPUT_BASE}"
    echo ""

    # Print the build queue in order
    echo "  Build queue:"
    local queue_num=0
    for v_entry in "${filtered_versions[@]}"; do
        local _m _f _r _e
        IFS=':' read -r _m _f _r _e <<< "$v_entry"
        for d_entry in "${filtered_targets[@]}"; do
            local _d _i _de
            IFS=':' read -r _d _i _de <<< "$d_entry"
            queue_num=$((queue_num + 1))
            printf "    %2d. postgresql-%-4s (%s) × %s\n" "$queue_num" "$_m" "$_f" "$_d"
        done
    done
    echo ""
    echo "───────────────────────────────────────────────────────────────────"
    echo ""

    # ── Sequential build loop ────────────────────────────────────────────
    local current=0
    for v_entry in "${filtered_versions[@]}"; do
        local pg_major pg_full pg_release pg_enabled
        IFS=':' read -r pg_major pg_full pg_release pg_enabled <<< "$v_entry"

        for d_entry in "${filtered_targets[@]}"; do
            local distro_id docker_image bt_enabled
            IFS=':' read -r distro_id docker_image bt_enabled <<< "$d_entry"

            current=$((current + 1))
            local package="postgresql-${pg_major}"
            local step_start
            step_start=$(date +%s)

            echo "┌─────────────────────────────────────────────────────────────────"
            echo "│ Step ${current} of ${total}: ${package} × ${distro_id}"
            echo "│ Builder: ${BUILDER}"
            echo "│ Version: ${pg_full}-${pg_release}"
            echo "└─────────────────────────────────────────────────────────────────"

            local rc=0
            local builder_fn="builder_$(get_builder_function_prefix "${BUILDER}")_build_rpm"
            "$builder_fn" \
                "$package" "$distro_id" "$pg_major" "$pg_full" "$pg_release" "$OUTPUT_BASE" || rc=$?

            local step_end
            step_end=$(date +%s)
            local step_duration=$((step_end - step_start))

            if [[ $rc -eq 0 ]]; then
                succeeded=$((succeeded + 1))
                log_success "[${current}/${total}] ${package} × ${distro_id} — OK (${step_duration}s)"
            else
                failed=$((failed + 1))
                failed_list+=("${package} × ${distro_id}")
                log_error "[${current}/${total}] ${package} × ${distro_id} — FAILED (${step_duration}s)"

                if [[ -n "$stop_on_error" ]]; then
                    log_error "Stopping: --stop-on-error is set"
                    echo ""
                    echo "═══════════════════════════════════════════════════════════════════"
                    echo "  Stopped early at step ${current} of ${total}"
                    echo "═══════════════════════════════════════════════════════════════════"
                    echo ""
                    echo "  Succeeded: ${succeeded}"
                    echo "  Failed:    ${failed}"
                    echo "  Remaining: $((total - current))"
                    echo ""
                    return 1
                fi
            fi

            # Log progress between builds
            if [[ $current -lt $total ]]; then
                local remaining=$((total - current))
                log_info "Progress: ${current}/${total} done, ${remaining} remaining"
            fi
            echo ""
        done
    done

    # ── Final summary ────────────────────────────────────────────────────
    local build_end
    build_end=$(date +%s)
    local build_duration=$((build_end - build_start))

    echo "═══════════════════════════════════════════════════════════════════"
    echo "  RPM Build Matrix Complete [${BUILDER}]"
    echo "═══════════════════════════════════════════════════════════════════"
    echo ""
    echo "  Scope:     ${scope}"
    echo "  Succeeded: ${succeeded}"
    echo "  Failed:    ${failed}"
    echo "  Duration:  ${build_duration}s"
    echo "  Output:    ${OUTPUT_BASE}/builds/${BUILDER}/"
    echo ""

    if [[ $failed -gt 0 ]]; then
        echo "  Failed builds:"
        for entry in "${failed_list[@]}"; do
            echo "    - ${entry}"
        done
        echo ""
        log_error "${failed} of ${total} build(s) failed"
        return 1
    fi

    log_success "All ${total} RPM build(s) completed successfully"
}

# ─── Build DEB Matrix (sequential) ───────────────────────────────────────
#
# Reads pipeline.conf for PG_VERSIONS and DEB_TARGETS, then builds
# DEB packages for the requested combinations one-by-one in strict sequential order.
#
# Optional filters (narrow the matrix):
#   --pg-major 17      Only build PG 17 (across all distros)
#   --distro bookworm  Only build for bookworm (across all PG versions)
#   both together       Build a single combination (PG17 × bookworm)
#   neither             Build ALL versions × ALL distros
#
# Flow control:
#   --stop-on-error     Stop the sequence immediately on first failure
#

cmd_build_all_deb() {
    local conf_file="${PROJECT_ROOT}/pipeline.conf"
    if [[ ! -f "$conf_file" ]]; then
        log_error "pipeline.conf not found at: ${conf_file}"
        exit 1
    fi

    # Source pipeline.conf to get PG_VERSIONS and DEB_BUILD_TARGETS
    source "$conf_file"

    # Use DEB_BUILD_TARGETS if available, fallback to BUILD_TARGETS
    local -a targets=(${DEB_BUILD_TARGETS[@]:-${BUILD_TARGETS[@]}})
    if [[ ${#targets[@]} -eq 0 ]]; then
        log_error "No DEB_TARGETS or BUILD_TARGETS defined in pipeline.conf"
        exit 1
    fi

    load_builder "$BUILDER"

    local stop_on_error="${ARG_STOP_ON_ERROR:-}"

    # ── Apply filters ────────────────────────────────────────────────────
    local filter_pg="${ARG_PG_MAJOR:-}"
    local filter_distro="${ARG_DISTRO:-}"

    # Build filtered lists
    local -a filtered_versions=()
    local -a filtered_targets=()

    for v_entry in "${PG_VERSIONS[@]}"; do
        local _maj
        IFS=':' read -r _maj _ _ _ <<< "$v_entry"
        if [[ -z "$filter_pg" ]] || [[ "$_maj" == "$filter_pg" ]]; then
            filtered_versions+=("$v_entry")
        fi
    done

    for d_entry in "${targets[@]}"; do
        local _dist
        IFS=':' read -r _dist _ _ <<< "$d_entry"
        if [[ -z "$filter_distro" ]] || [[ "$_dist" == "$filter_distro" ]]; then
            filtered_targets+=("$d_entry")
        fi
    done

    # Validate filters matched something
    if [[ ${#filtered_versions[@]} -eq 0 ]]; then
        log_error "No PG version matched '${filter_pg}'"
        log_info "Available versions: $(printf '%s ' "${PG_VERSIONS[@]}" | sed 's/:[^ ]* */ /g')"
        exit 1
    fi
    if [[ ${#filtered_targets[@]} -eq 0 ]]; then
        log_error "No DEB distro matched '${filter_distro}'"
        log_info "Available distros: $(printf '%s ' "${targets[@]}" | sed 's/:[^ ]* */ /g')"
        exit 1
    fi

    # ── Summary ──────────────────────────────────────────────────────────
    local total=$(( ${#filtered_versions[@]} * ${#filtered_targets[@]} ))
    local failed=0
    local succeeded=0
    local -a failed_list=()
    local build_start
    build_start=$(date +%s)

    # Build a readable scope label
    local scope="ALL"
    if [[ -n "$filter_pg" ]] && [[ -n "$filter_distro" ]]; then
        scope="PG${filter_pg} × ${filter_distro}"
    elif [[ -n "$filter_pg" ]]; then
        scope="PG${filter_pg} × all distros"
    elif [[ -n "$filter_distro" ]]; then
        scope="all versions × ${filter_distro}"
    fi

    echo ""
    echo "═══════════════════════════════════════════════════════════════════"
    echo "  build-env.sh — DEB Build Matrix [${BUILDER}]"
    echo "═══════════════════════════════════════════════════════════════════"
    echo ""
    echo "  Scope:          ${scope}"
    echo "  Builder:        ${BUILDER}"
    echo "  PG versions:    ${#filtered_versions[@]} of ${#PG_VERSIONS[@]}"
    echo "  DEB distros:    ${#filtered_targets[@]} of ${#targets[@]}"
    echo "  Total builds:   ${total}"
    echo "  Execution:      sequential (one at a time)"
    echo "  Stop on error:  $([ -n "$stop_on_error" ] && echo "yes" || echo "no")"
    echo "  Output:         ${OUTPUT_BASE}"
    echo ""

    # Print the build queue in order
    echo "  Build queue:"
    local queue_num=0
    for v_entry in "${filtered_versions[@]}"; do
        local _m _f _r _e
        IFS=':' read -r _m _f _r _e <<< "$v_entry"
        for d_entry in "${filtered_targets[@]}"; do
            local _d _i _de
            IFS=':' read -r _d _i _de <<< "$d_entry"
            queue_num=$((queue_num + 1))
            printf "    %2d. postgresql-%-4s (%s) × %s\n" "$queue_num" "$_m" "$_f" "$_d"
        done
    done
    echo ""
    echo "───────────────────────────────────────────────────────────────────"
    echo ""

    # ── Sequential build loop ────────────────────────────────────────────
    local current=0
    for v_entry in "${filtered_versions[@]}"; do
        local pg_major pg_full pg_release pg_enabled
        IFS=':' read -r pg_major pg_full pg_release pg_enabled <<< "$v_entry"

        for d_entry in "${filtered_targets[@]}"; do
            local distro_id docker_image bt_enabled
            IFS=':' read -r distro_id docker_image bt_enabled <<< "$d_entry"

            current=$((current + 1))
            local package="postgresql-${pg_major}"
            local step_start
            step_start=$(date +%s)

            echo "┌─────────────────────────────────────────────────────────────────"
            echo "│ Step ${current} of ${total}: ${package} × ${distro_id}"
            echo "│ Builder: ${BUILDER}"
            echo "│ Version: ${pg_full}-${pg_release}"
            echo "└─────────────────────────────────────────────────────────────────"

            local rc=0
            local builder_fn="builder_$(get_builder_function_prefix "${BUILDER}")_build_deb"
            "$builder_fn" \
                "$package" "$distro_id" "$pg_major" "$pg_full" "$pg_release" "$OUTPUT_BASE" || rc=$?

            local step_end
            step_end=$(date +%s)
            local step_duration=$((step_end - step_start))

            if [[ $rc -eq 0 ]]; then
                succeeded=$((succeeded + 1))
                log_success "[${current}/${total}] ${package} × ${distro_id} — OK (${step_duration}s)"
            else
                failed=$((failed + 1))
                failed_list+=("${package} × ${distro_id}")
                log_error "[${current}/${total}] ${package} × ${distro_id} — FAILED (${step_duration}s)"

                if [[ -n "$stop_on_error" ]]; then
                    log_error "Stopping: --stop-on-error is set"
                    echo ""
                    echo "═══════════════════════════════════════════════════════════════════"
                    echo "  Stopped early at step ${current} of ${total}"
                    echo "═══════════════════════════════════════════════════════════════════"
                    echo ""
                    echo "  Succeeded: ${succeeded}"
                    echo "  Failed:    ${failed}"
                    echo "  Remaining: $((total - current))"
                    echo ""
                    return 1
                fi
            fi

            # Log progress between builds
            if [[ $current -lt $total ]]; then
                local remaining=$((total - current))
                log_info "Progress: ${current}/${total} done, ${remaining} remaining"
            fi
            echo ""
        done
    done

    # ── Final summary ────────────────────────────────────────────────────
    local build_end
    build_end=$(date +%s)
    local build_duration=$((build_end - build_start))

    echo "═══════════════════════════════════════════════════════════════════"
    echo "  DEB Build Matrix Complete [${BUILDER}]"
    echo "═══════════════════════════════════════════════════════════════════"
    echo ""
    echo "  Scope:     ${scope}"
    echo "  Succeeded: ${succeeded}"
    echo "  Failed:    ${failed}"
    echo "  Duration:  ${build_duration}s"
    echo "  Output:    ${OUTPUT_BASE}/builds/${BUILDER}/"
    echo ""

    if [[ $failed -gt 0 ]]; then
        echo "  Failed builds:"
        for entry in "${failed_list[@]}"; do
            echo "    - ${entry}"
        done
        echo ""
        log_error "${failed} of ${total} build(s) failed"
        return 1
    fi

    log_success "All ${total} DEB build(s) completed successfully"
}

cmd_check() {
    load_builder "$BUILDER"

    echo ""
    echo "Checking build environment: ${BUILDER}"
    echo "════════════════════════════════════════"
    echo ""

    local rc=0
    local builder_fn="builder_$(get_builder_function_prefix "${BUILDER}")_check_deps"
    "$builder_fn" || rc=$?

    echo ""
    if [[ $rc -eq 0 ]]; then
        log_success "Build environment '${BUILDER}' is ready"
    else
        log_error "Build environment '${BUILDER}' has missing dependencies"
    fi

    return $rc
}

cmd_setup() {
    load_builder "$BUILDER"

    local setup_fn="builder_$(get_builder_function_prefix "${BUILDER}")_setup"
    if declare -f "$setup_fn" &>/dev/null; then
        "$setup_fn" ${ARG_NO_CACHE}
    else
        log_info "No setup needed for '${BUILDER}' builder"
    fi
}

cmd_shell() {
    local distro="${ARG_DISTRO:-EL-9}"
    load_builder "$BUILDER"

    local shell_fn="builder_$(get_builder_function_prefix "${BUILDER}")_shell"
    if declare -f "$shell_fn" &>/dev/null; then
        "$shell_fn" "$distro"
    else
        log_error "Shell not supported for '${BUILDER}' builder"
        exit 1
    fi
}

cmd_clean() {
    load_builder "$BUILDER"

    local clean_fn="builder_$(get_builder_function_prefix "${BUILDER}")_clean"
    if declare -f "$clean_fn" &>/dev/null; then
        "$clean_fn" "${ARG_DISTRO:-}"
    else
        log_info "No cleanup needed for '${BUILDER}' builder"
    fi
}

cmd_list_builders() {
    echo ""
    echo "Available Build Environments"
    echo "════════════════════════════════════════════════════════════════"
    echo ""
    printf "  %-14s %-10s %-10s %s\n" "Builder" "RPM" "DEB" "Description"
    echo "  ────────────────────────────────────────────────────────────────"
    printf "  %-14s %-10s %-10s %s\n" "docker"       "yes" "yes" "Docker containers — default, most isolated (RPM + DEB)"
    printf "  %-14s %-10s %-10s %s\n" "docker-sbuild" "no" "yes" "Docker + sbuild + mmdebstrap — isolated DEB builds"
    printf "  %-14s %-10s %-10s %s\n" "mmdebstrap"   "no"  "yes" "mmdebstrap + sbuild — 5-10x faster than Docker for DEB"
    printf "  %-14s %-10s %-10s %s\n" "sbuild"       "no"  "yes" "Traditional sbuild + debootstrap — standard Debian approach"
    printf "  %-14s %-10s %-10s %s\n" "mock"         "yes" "no"  "Mock chroot — standard Fedora/EPEL/CentOS RPM tool"
    printf "  %-14s %-10s %-10s %s\n" "pbuilder"     "no"  "yes" "pbuilder/cowbuilder — Debian/Ubuntu chroot for DEB"
    printf "  %-14s %-10s %-10s %s\n" "direct"       "yes" "yes" "Local host — no isolation, fastest for development"
    echo ""
    echo "  Current default: ${BUILDER}"
    echo ""
    echo "  Set via:"
    echo "    --builder=<name>        Command-line flag"
    echo "    BUILD_ENV=<name>        Environment variable"
    echo "    BUILD_ENV=\"<name>\"      pipeline.conf setting"
    echo ""

    # Check which builders are available on this system
    echo "  Availability on this system:"
    echo "  ────────────────────────────────────────────────────────────────"
    local b check_fn
    for b in docker docker-sbuild mmdebstrap sbuild mock pbuilder direct; do
        source "${SCRIPT_DIR}/build-envs/${b}.sh" 2>/dev/null || continue
        check_fn="builder_${b}_check_deps"
        if declare -f "$check_fn" &>/dev/null; then
            if "$check_fn" &>/dev/null 2>&1; then
                printf "  %-12s ${GREEN}available${NC}\n" "$b"
            else
                printf "  %-12s ${DIM}not ready${NC}\n" "$b"
            fi
        fi
    done
    echo ""
}

cmd_status() {
    echo ""
    echo "Build Environment Configuration"
    echo "════════════════════════════════════════════════════════════════"
    echo ""
    echo "  Default builder:  ${BUILDER}"
    echo "  Output directory: ${OUTPUT_BASE}"
    echo "  Project root:     ${PROJECT_ROOT}"
    echo ""

    # Show output directory structure if it exists
    if [[ -d "${OUTPUT_BASE}/builds" ]]; then
        echo "  Current build outputs:"
        echo "  ──────────────────────────────────────────────────────────────"

        for builder_dir in "${OUTPUT_BASE}/builds"/*/; do
            [[ -d "$builder_dir" ]] || continue
            local builder
            builder=$(basename "$builder_dir")
            echo "    ${builder}/"

            for distro_dir in "${builder_dir}"/*/; do
                [[ -d "$distro_dir" ]] || continue
                local distro
                distro=$(basename "$distro_dir")
                echo "      ${distro}/"

                for pkg_dir in "${distro_dir}"/*/; do
                    [[ -d "$pkg_dir" ]] || continue
                    local pkg
                    pkg=$(basename "$pkg_dir")
                    local rpm_count deb_count
                    rpm_count=$(find "${pkg_dir}/RPMS" -name '*.rpm' 2>/dev/null | wc -l)
                    deb_count=$(find "${pkg_dir}/DEBS" -name '*.deb' 2>/dev/null | wc -l)
                    echo "        ${pkg}/ (${rpm_count} RPMs, ${deb_count} DEBs)"
                done
            done
        done
        echo ""
    fi

    # Show repo directory if it exists
    if [[ -d "${OUTPUT_BASE}/repos" ]]; then
        echo "  Repository outputs:"
        echo "  ──────────────────────────────────────────────────────────────"

        if [[ -d "${OUTPUT_BASE}/repos/rpm" ]]; then
            for distro_dir in "${OUTPUT_BASE}/repos/rpm"/*/; do
                [[ -d "$distro_dir" ]] || continue
                local distro
                distro=$(basename "$distro_dir")
                local count
                count=$(find "$distro_dir" -name '*.rpm' 2>/dev/null | wc -l)
                echo "    rpm/${distro}/ (${count} RPMs)"
            done
        fi

        if [[ -d "${OUTPUT_BASE}/repos/deb" ]]; then
            for dist_dir in "${OUTPUT_BASE}/repos/deb"/*/; do
                [[ -d "$dist_dir" ]] || continue
                local dist
                dist=$(basename "$dist_dir")
                local count
                count=$(find "$dist_dir" -name '*.deb' 2>/dev/null | wc -l)
                echo "    deb/${dist}/ (${count} DEBs)"
            done
        fi
        echo ""
    fi

    # Show logs
    if [[ -d "${OUTPUT_BASE}/logs" ]]; then
        local log_count
        log_count=$(find "${OUTPUT_BASE}/logs" -name '*.log' 2>/dev/null | wc -l)
        echo "  Build logs: ${log_count} log files in ${OUTPUT_BASE}/logs/"
        echo ""
    fi
}

# ═══════════════════════════════════════════════════════════════════════════
#  Integrated Local Build & Test Commands
# ═══════════════════════════════════════════════════════════════════════════
#
# These commands merge the functionality of the former local-build-test.sh
# and install-sql-test.sh into this single entry point, with minute
# phase-level control over every stage of build and test.

# ─── Constants for test commands ──────────────────────────────────────────

TEST_IMAGE_PREFIX="postgresql-build-test"
TEST_RPM_DISTROS=(el8 el9 el10 amazonlinux2023 centos-stream9 fedora42 fedora43)
TEST_DEB_DISTROS=(debian-bookworm debian-bullseye ubuntu-jammy ubuntu-noble ubuntu-focal)
TEST_ALL_DISTROS=("${TEST_RPM_DISTROS[@]}" "${TEST_DEB_DISTROS[@]}")

# Determine package type (rpm or deb) from distro name
_test_get_pkg_type() {
    local distro="$1"
    if [[ -n "$ARG_PKG_TYPE" ]]; then
        echo "$ARG_PKG_TYPE"
        return
    fi
    case "$distro" in
        el*|amazonlinux*|centos*|fedora*) echo "rpm" ;;
        noble|focal|jammy|bookworm|bullseye|trixie|debian*|ubuntu*)                  echo "deb" ;;
        *) echo "unknown" ;;
    esac
}

# Check if a phase is enabled
_phase_enabled() {
    local phase="$1"
    local phases="${ARG_PHASE:-all}"
    if [[ "$phases" == "all" ]]; then
        return 0
    fi
    echo ",$phases," | grep -q ",$phase,"
}

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

# Build Docker image for a test distribution
_test_build_image() {
    local distro="$1"
    local tag=$(_docker_image_tag "$distro")
    local docker_dir="${PROJECT_ROOT}/docker/${tag}"
    local image_tag="${TEST_IMAGE_PREFIX}:${tag}"

    if [[ ! -d "$docker_dir" ]]; then
        log_error "Docker context not found: $docker_dir"
        return 1
    fi
    if [[ ! -f "$docker_dir/Dockerfile" ]]; then
        log_error "Dockerfile not found: $docker_dir/Dockerfile"
        return 1
    fi

    log_info "Building Docker image: $image_tag"
    local log_dir="${OUTPUT_BASE}/test-output/logs"
    mkdir -p "$log_dir"
    if docker build -t "$image_tag" "$docker_dir" 2>&1 | tee "$log_dir/${distro}-docker-build.log"; then
        log_success "Docker image built: $image_tag"
        return 0
    else
        log_error "Docker image build failed: $image_tag"
        return 1
    fi
}

# Test RPM build environment inside container
_test_rpm_env() {
    local distro="$1"
    local pg_major="${ARG_PG_MAJOR:-16}"
    local image_tag="${TEST_IMAGE_PREFIX}:${distro}"
    local container_name="pg-test-${distro}-$$"
    local log_dir="${OUTPUT_BASE}/test-output/logs"
    mkdir -p "$log_dir"

    log_info "Testing RPM build environment: $distro (PG $pg_major)"

    local test_script
    test_script=$(cat <<'TESTEOF'
#!/bin/bash
set -e
echo "=== RPM Build Environment Test ==="
echo "Distribution: $(cat /etc/os-release | grep PRETTY_NAME | cut -d= -f2)"
echo "Architecture: $(uname -m)"
echo ""
echo "--- Checking build tools ---"
rpm --version
rpmbuild --version
gcc --version | head -1
make --version | head -1
echo ""
echo "--- Checking PostgreSQL build dependencies ---"
for pkg in readline-devel zlib-devel openssl-devel libxml2-devel \
           libxslt-devel pam-devel openldap-devel krb5-devel \
           libicu-devel systemd-devel; do
    if rpm -q "$pkg" &>/dev/null; then
        echo "  [OK] $pkg"
    else
        echo "  [MISSING] $pkg"
    fi
done
echo ""
echo "--- Checking LLVM/Clang ---"
if command -v clang &>/dev/null; then
    echo "  [OK] clang: $(clang --version | head -1)"
else
    echo "  [MISSING] clang"
fi
echo ""
echo "--- Checking RPM build tree ---"
ls -d ~/rpmbuild/{BUILD,BUILDROOT,RPMS,SRPMS,SOURCES,SPECS} 2>/dev/null && echo "  [OK] rpmbuild tree" || echo "  [MISSING] rpmbuild tree"
echo ""
echo "--- Testing spec file parsing ---"
cat > /tmp/test.spec << 'SPECEOF'
Name: test-pg
Version: 1.0
Release: 1%{?dist}
Summary: Test spec
License: PostgreSQL
%description
Test package
%prep
%build
%install
%files
SPECEOF
if rpmbuild --nobuild /tmp/test.spec &>/dev/null; then
    echo "  [OK] RPM spec parsing works"
else
    echo "  [WARN] RPM spec parsing issue (non-critical)"
fi
echo ""
echo "=== RPM Build Environment Test Complete ==="
TESTEOF
)
    if docker run --rm --name "$container_name" \
        -v "${PROJECT_ROOT}:/home/builder/packaging:ro" \
        "$image_tag" bash -c "$test_script" 2>&1 | tee "$log_dir/${distro}-rpm-test.log"; then
        log_success "RPM build environment test passed: $distro"
        return 0
    else
        log_error "RPM build environment test failed: $distro"
        return 1
    fi
}

# Test DEB build environment inside container
_test_deb_env() {
    local distro="$1"
    local pg_major="${ARG_PG_MAJOR:-16}"
    local image_tag="${TEST_IMAGE_PREFIX}:${distro}"
    local container_name="pg-test-${distro}-$$"
    local log_dir="${OUTPUT_BASE}/test-output/logs"
    mkdir -p "$log_dir"

    log_info "Testing DEB build environment: $distro (PG $pg_major)"

    local test_script
    test_script=$(cat <<'TESTEOF'
#!/bin/bash
set -e
echo "=== DEB Build Environment Test ==="
echo "Distribution: $(cat /etc/os-release | grep PRETTY_NAME | cut -d= -f2)"
echo "Architecture: $(dpkg --print-architecture)"
echo ""
echo "--- Checking build tools ---"
dpkg --version | head -1
dpkg-buildpackage --version 2>/dev/null | head -1 || echo "dpkg-buildpackage available"
gcc --version | head -1
make --version | head -1
fakeroot --version
echo ""
echo "--- Checking PostgreSQL build dependencies ---"
for pkg in libreadline-dev zlib1g-dev libssl-dev libxml2-dev \
           libxslt1-dev libpam0g-dev libldap2-dev libkrb5-dev \
           libicu-dev libsystemd-dev liblz4-dev libzstd-dev; do
    if dpkg -s "$pkg" &>/dev/null; then
        echo "  [OK] $pkg"
    else
        echo "  [MISSING] $pkg"
    fi
done
echo ""
echo "--- Checking LLVM/Clang ---"
if command -v clang &>/dev/null; then
    echo "  [OK] clang: $(clang --version | head -1)"
else
    echo "  [MISSING] clang"
fi
echo ""
echo "--- Checking DEB build directories ---"
ls -d ~/debbuild/{BUILD,DEBS,SOURCES} 2>/dev/null && echo "  [OK] debbuild tree" || echo "  [MISSING] debbuild tree"
ls -d ~/output/DEBS 2>/dev/null && echo "  [OK] output/DEBS" || echo "  [MISSING] output/DEBS"
echo ""
echo "--- Checking debhelper ---"
if dpkg -s debhelper &>/dev/null; then
    echo "  [OK] debhelper version: $(dpkg -s debhelper | grep Version | cut -d: -f2)"
else
    echo "  [MISSING] debhelper"
fi
echo ""
echo "=== DEB Build Environment Test Complete ==="
TESTEOF
)
    if docker run --rm --name "$container_name" \
        -v "${PROJECT_ROOT}:/home/builder/packaging:ro" \
        "$image_tag" bash -c "$test_script" 2>&1 | tee "$log_dir/${distro}-deb-test.log"; then
        log_success "DEB build environment test passed: $distro"
        return 0
    else
        log_error "DEB build environment test failed: $distro"
        return 1
    fi
}

# Resolve test target distros from --distro argument
_test_resolve_targets() {
    local distro="${ARG_DISTRO:-}"
    if [[ -z "$distro" ]] || [[ "$distro" == "all" ]]; then
        echo "${TEST_ALL_DISTROS[@]}"
    elif [[ "$distro" == "rpm" ]]; then
        echo "${TEST_RPM_DISTROS[@]}"
    elif [[ "$distro" == "deb" ]]; then
        echo "${TEST_DEB_DISTROS[@]}"
    else
        echo "$distro"
    fi
}

# Cleanup test images
_test_cleanup_images() {
    if [[ -n "${ARG_NO_CLEANUP}" ]]; then
        log_info "Skipping cleanup (--no-cleanup)"
        return
    fi
    log_info "Cleaning up test images..."
    for distro in "${TEST_ALL_DISTROS[@]}"; do
        local image_tag="${TEST_IMAGE_PREFIX}:${distro}"
        if docker image inspect "$image_tag" &>/dev/null; then
            docker rmi "$image_tag" 2>/dev/null || true
        fi
    done
}

# ─── Command: test-env ────────────────────────────────────────────────────
#
# Test build environment for one or more distributions.
# Builds Docker images and validates that all required build tools and
# dependencies are present inside each container.
#
# Flags:
#   --distro DISTRO   Target: el9, debian-bookworm, rpm, deb, all (default: all)
#   --pg-major VER    PostgreSQL major version for context (default: 16)
#   --no-cleanup      Keep test Docker images after test
#   --dry-run         Show what would be tested without running

cmd_test_env() {
    local targets
    read -ra targets <<< "$(_test_resolve_targets)"

    if [[ -n "${ARG_DRY_RUN}" ]]; then
        echo ""
        echo "Dry run — would test the following distributions:"
        for t in "${targets[@]}"; do
            echo "  - $t ($(_test_get_pkg_type "$t"))"
        done
        echo ""
        return 0
    fi

    echo ""
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║        Build Environment Test                               ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo ""

    local pg_major="${ARG_PG_MAJOR:-16}"
    log_info "PostgreSQL version: $pg_major"
    log_info "Target distros:     ${targets[*]}"
    log_info "Output dir:         ${OUTPUT_BASE}/test-output"
    echo ""

    local test_output="${OUTPUT_BASE}/test-output"
    mkdir -p "$test_output/logs" "$test_output/results"

    local passed=0 failed=0
    local failed_distros=()

    for distro in "${targets[@]}"; do
        local pkg_type
        pkg_type="$(_test_get_pkg_type "$distro")"

        log_info "─────────────────────────────────────────────"
        log_info "Testing distribution: $distro (${pkg_type})"
        log_info "─────────────────────────────────────────────"

        local ok=true

        if ! _test_build_image "$distro"; then
            ok=false
        fi

        if $ok; then
            case "$pkg_type" in
                rpm) _test_rpm_env "$distro" || ok=false ;;
                deb) _test_deb_env "$distro" || ok=false ;;
                *)   log_error "Unknown package type for $distro"; ok=false ;;
            esac
        fi

        if $ok; then
            passed=$((passed + 1))
        else
            failed=$((failed + 1))
            failed_distros+=("$distro")
        fi
        echo ""
    done

    echo ""
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║        Build Environment Results                            ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo ""
    log_info "Total: $((passed + failed)) | Passed: $passed | Failed: $failed"

    if [[ ${#failed_distros[@]} -gt 0 ]]; then
        log_error "Failed: ${failed_distros[*]}"
        log_info "Check logs in: $test_output/logs/"
    fi

    cat > "$test_output/results/summary.txt" << EOF
Build Environment Test Results
==============================
Date: $(date -u +"%Y-%m-%d %H:%M:%S UTC")
PG Version: ${pg_major}

Total:  $((passed + failed))
Passed: $passed
Failed: $failed

Tested distributions:
$(for d in "${targets[@]}"; do echo "  - $d"; done)

$(if [[ ${#failed_distros[@]} -gt 0 ]]; then
    echo "Failed:"
    for d in "${failed_distros[@]}"; do echo "  - $d"; done
fi)
EOF

    log_info "Results saved to: $test_output/results/summary.txt"

    _test_cleanup_images

    [[ $failed -eq 0 ]]
}

# ─── Command: test-quick ──────────────────────────────────────────────────
#
# Quick Dockerfile-only validation. Builds Docker images for all target
# distributions but does NOT run environment tests inside them.
# Fastest validation — useful for CI pre-checks.
#
# Flags:
#   --distro DISTRO   Target: el9, debian-bookworm, rpm, deb, all (default: all)
#   --no-cleanup      Keep test Docker images after test
#   --dry-run         Show targets without running

cmd_test_quick() {
    local targets
    read -ra targets <<< "$(_test_resolve_targets)"

    if [[ -n "${ARG_DRY_RUN}" ]]; then
        echo ""
        echo "Dry run — would validate Dockerfiles for:"
        for t in "${targets[@]}"; do
            echo "  - $t"
        done
        echo ""
        return 0
    fi

    echo ""
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║        Quick Dockerfile Validation                          ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo ""

    log_info "Target distros: ${targets[*]}"
    echo ""

    local passed=0 failed=0
    local failed_distros=()

    for distro in "${targets[@]}"; do
        if _test_build_image "$distro"; then
            passed=$((passed + 1))
        else
            failed=$((failed + 1))
            failed_distros+=("$distro")
        fi
    done

    echo ""
    log_info "Quick validation: $passed passed, $failed failed"
    if [[ ${#failed_distros[@]} -gt 0 ]]; then
        log_error "Failed: ${failed_distros[*]}"
    fi

    _test_cleanup_images

    [[ $failed -eq 0 ]]
}

# ─── Command: test-install ─────────────────────────────────────────────────
#
# Full build-install-test cycle in a Docker container:
#   Phase: env      — Ensure Docker image exists
#   Phase: build    — Build PostgreSQL from source (or use --pkg-dir)
#   Phase: install  — Install built packages
#   Phase: init     — Initialize cluster and start PostgreSQL
#   Phase: check    — Run installation health checks
#   Phase: sql      — Run SQL test suite
#
# Fine-grained control:
#   --phase env,build,install     Run only specific phases (comma-separated)
#   --phase all                   Run all phases (default)
#   --pkg-dir DIR                 Skip build phase; use pre-built packages
#   --filter PATTERN              SQL test filter (e.g., "01_*")
#   --category CAT                SQL test category filter
#   --sql-stop-on-failure         Stop SQL tests at first failure
#   --keep                        Keep container after test
#   --dry-run                     Show plan without executing

cmd_test_install() {
    local distro="${ARG_DISTRO:-el9}"
    local pg_major="${ARG_PG_MAJOR:-16}"
    local phases="${ARG_PHASE:-all}"
    local pkg_dir="${ARG_PKG_DIR:-}"
    local pkg_type
    pkg_type="$(_test_get_pkg_type "$distro")"

    if [[ "$pkg_type" == "unknown" ]]; then
        log_error "Unknown distribution: $distro"
        exit 1
    fi

    if [[ -n "$pkg_dir" ]] && [[ ! -d "$pkg_dir" ]]; then
        log_error "Package directory not found: $pkg_dir"
        exit 1
    fi

    local test_output="${OUTPUT_BASE}/test-output/install-sql"
    export container_name="pg-install-test-$$"
    local tag=$(_docker_image_tag "$distro")
    local image_tag="${TEST_IMAGE_PREFIX}:${tag}"
    local pgbin
    if [[ "$pkg_type" == "deb" ]]; then
        pgbin="/usr/lib/postgresql/${pg_major}/bin"
    else
        pgbin="/usr/pgsql-${pg_major}/bin"
    fi

    # Determine which phases to run
    local run_env=false run_build=false run_install=false run_init=false run_check=false run_sql=false
    if [[ "$phases" == "all" ]]; then
        run_env=true; run_build=true; run_install=true; run_init=true; run_check=true; run_sql=true
    else
        IFS=',' read -ra phase_list <<< "$phases"
        for p in "${phase_list[@]}"; do
            case "$p" in
                env)     run_env=true ;;
                build)   run_build=true ;;
                install) run_install=true ;;
                init)    run_init=true ;;
                check)   run_check=true ;;
                sql)     run_sql=true ;;
                *) log_error "Unknown phase: $p (valid: env,build,install,init,check,sql)"; exit 1 ;;
            esac
        done
    fi

    # If --pkg-dir is provided, skip build phase
    if [[ -n "$pkg_dir" ]]; then
        run_build=false
    fi

    if [[ -n "${ARG_DRY_RUN}" ]]; then
        echo ""
        echo "Dry run — test-install plan:"
        echo "  Distribution: $distro ($pkg_type)"
        echo "  PG Version:   $pg_major"
        echo "  Phases:"
        $run_env     && echo "    [x] env     — Ensure Docker image"
        $run_build   && echo "    [x] build   — Build PostgreSQL from source"
        $run_install && echo "    [x] install — Install packages"
        $run_init    && echo "    [x] init    — Initialize cluster & start PG"
        $run_check   && echo "    [x] check   — Run health checks"
        $run_sql     && echo "    [x] sql     — Run SQL test suite"
        $run_env     || echo "    [ ] env"
        $run_build   || echo "    [ ] build"
        $run_install || echo "    [ ] install"
        $run_init    || echo "    [ ] init"
        $run_check   || echo "    [ ] check"
        $run_sql     || echo "    [ ] sql"
        [[ -n "$pkg_dir" ]] && echo "  Pre-built packages: $pkg_dir"
        [[ -n "$ARG_FILTER" ]] && echo "  SQL filter: $ARG_FILTER"
        [[ -n "$ARG_CATEGORY" ]] && echo "  SQL category: $ARG_CATEGORY"
        echo ""
        return 0
    fi

    echo ""
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║     PostgreSQL Installation & SQL Test                      ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo ""

    mkdir -p "$test_output/logs" "$test_output/sql-results"

    log_info "Distribution: $distro ($pkg_type)"
    log_info "PG Version:   $pg_major"
    log_info "Phases:       $phases"
    if [[ -n "$pkg_dir" ]]; then
        log_info "Packages:     $pkg_dir (pre-built)"
    else
        log_info "Packages:     build from source"
    fi
    echo ""

    local BUILD_OK=0 INSTALL_OK=0 SQL_OK=0

    # Cleanup handler
    _test_install_cleanup() {
        if [[ -z "${ARG_KEEP}" ]]; then
            log_info "Cleaning up container: $container_name"
            docker rm -f "$container_name" 2>/dev/null || true
        else
            log_info "Keeping container: $container_name (--keep)"
            log_info "  Attach: docker exec -it $container_name bash"
            log_info "  psql:   docker exec -it $container_name psql -U postgres"
        fi
    }
    trap _test_install_cleanup EXIT

    # ── Phase: env ────────────────────────────────────────────────────────
    if $run_env; then
        log_info "═══ Phase: env — Ensure Build Image ═══"
        echo ""

        if ! docker image inspect "$image_tag" &>/dev/null; then
            if ! _test_build_image "$distro"; then
                log_error "Cannot proceed without build image"
                exit 1
            fi
        else
            log_info "Build image found: $image_tag"
        fi

        # Start the container
        local docker_run_args=(
            -d --name "$container_name"
            --user root
            --shm-size=256m
            -v "${PROJECT_ROOT}:/home/builder/packaging:ro"
        )
        if [[ -n "$pkg_dir" ]]; then
            docker_run_args+=(-v "$(cd "$pkg_dir" && pwd):/tmp/packages:ro")
        fi

        log_info "Starting test container: $container_name"
        docker run "${docker_run_args[@]}" "$image_tag" sleep infinity

        docker exec "$container_name" bash -c "
            id postgres &>/dev/null 2>&1 || useradd -r -m -s /bin/bash postgres
            mkdir -p /tmp/pgdata /tmp/sql-tests /tmp/sql-results
            chown postgres:postgres /tmp/pgdata
        "
        echo ""
    fi

    # ── Phase: build ──────────────────────────────────────────────────────
    if $run_build; then
        log_info "═══ Phase: build — Build PostgreSQL from Source ═══"
        echo ""

        docker exec "$container_name" bash -c "
            set -e
            PG_MAJOR=${pg_major}
            echo '--- Downloading PostgreSQL source ---'
            cd /tmp
            PG_FULL=\$(wget -q -O - https://ftp.postgresql.org/pub/source/ 2>/dev/null | \
                grep -oP \"v\${PG_MAJOR}\.[0-9]+\" | sort -V | tail -1 | sed 's/^v//' || echo \"\${PG_MAJOR}.0\")
            echo \"PostgreSQL version: \${PG_FULL}\"
            if [ ! -f postgresql-\${PG_FULL}.tar.bz2 ]; then
                wget -q --show-progress https://ftp.postgresql.org/pub/source/v\${PG_FULL}/postgresql-\${PG_FULL}.tar.bz2
            fi
            echo '--- Extracting source ---'
            tar -xjf postgresql-\${PG_FULL}.tar.bz2
            cd postgresql-\${PG_FULL}
            echo '--- Configuring ---'
            ./configure \
                --prefix=/usr/pgsql-\${PG_MAJOR} \
                --with-openssl \
                --with-libxml \
                --with-icu \
                --with-systemd \
                --with-lz4 \
                --with-zstd \
                --with-llvm \
                CLANG=clang LLVM_CONFIG=llvm-config \
                2>&1 | tail -5
            echo '--- Compiling ---'
            make -j\$(nproc) 2>&1 | tail -3
            echo '--- Compiling contrib modules ---'
            make -C contrib -j\$(nproc) 2>&1 | tail -3
            echo '--- Build complete ---'
        " 2>&1 | tee "$test_output/logs/build.log"
        BUILD_OK=1
        echo ""
    fi

    # ── Phase: install ────────────────────────────────────────────────────
    if $run_install; then
        log_info "═══ Phase: install — Install PostgreSQL ═══"
        echo ""

        if [[ -n "$pkg_dir" ]]; then
            # Install from pre-built packages
            case "$pkg_type" in
                rpm)
                    docker exec "$container_name" bash -c "
                        set -e
                        echo '--- Installing RPM packages ---'
                        ls -1 /tmp/packages/*.rpm 2>/dev/null || { echo 'No RPM files found'; exit 1; }
                        rpm -ivh /tmp/packages/*.rpm --nodeps 2>&1 || true
                        echo '--- Verifying installation ---'
                        ls /usr/pgsql-${pg_major}/bin/postgres 2>/dev/null && echo '[OK] postgres binary' || \
                        ls /usr/pgsql-*/bin/postgres 2>/dev/null && echo '[OK] postgres binary (alt path)'
                    " 2>&1 | tee "$test_output/logs/install.log"
                    ;;
                deb)
                    docker exec "$container_name" bash -c "
                        set -e
                        export DEBIAN_FRONTEND=noninteractive

                        echo '--- Installing DEB packages with dependency resolution ---'

                        apt-get update

                        apt-get install -y \
                            locales \
                            ssl-cert \
                            postgresql-common \
                            postgresql-client-common \
                            libssl-dev \
                            libllvm14 \
                            libxslt1.1 \
                            libtcl8.6 \
                            clang-14 \
                            llvm-14-dev

                        echo '--- Installing DEB packages ---'
                        ls -1 /tmp/packages/*.deb 2>/dev/null || { echo 'No DEB files found'; exit 1; }
                        dpkg -i /tmp/packages/*.deb  || apt-get install -f -y
                        echo '--- Verifying installation ---'
                        ls /usr/lib/postgresql/${pg_major}/bin/postgres 2>/dev/null && echo '[OK] postgres binary' || \
                        ls /usr/pgsql-${pg_major}/bin/postgres 2>/dev/null && echo '[OK] postgres binary (alt path)'
                    " 2>&1 | tee "$test_output/logs/install.log"
                    ;;
            esac
        else
            # Install from source build
            docker exec "$container_name" bash -c "
                set -e
                PG_MAJOR=${pg_major}
                cd /tmp/postgresql-*/
                make install 2>&1 | tail -3
                make -C contrib install 2>&1 | tail -3
                echo '/usr/pgsql-${pg_major}/lib' > /etc/ld.so.conf.d/pgsql-${pg_major}.conf
                ldconfig
                echo '--- Installed to /usr/pgsql-${pg_major} ---'
                ls /usr/pgsql-${pg_major}/bin/postgres && echo '[OK] postgres binary'
                ls /usr/pgsql-${pg_major}/bin/psql && echo '[OK] psql binary'
                ls /usr/pgsql-${pg_major}/bin/pg_isready && echo '[OK] pg_isready binary'
            " 2>&1 | tee -a "$test_output/logs/install.log"
        fi
        INSTALL_OK=1
        echo ""
    fi

    # ── Phase: init ───────────────────────────────────────────────────────
    if $run_init; then
        log_info "═══ Phase: init — Initialize & Start PostgreSQL ═══"
        echo ""

        docker exec "$container_name" bash -c "
            set -e
            PGBIN=${pgbin}
            PGDATA=/tmp/pgdata

            if [ ! -f \${PGBIN}/initdb ]; then
                echo 'WARN: initdb not found at \${PGBIN}/initdb, searching...'
                FOUND=\$(find / -name initdb -type f 2>/dev/null | head -1)
                if [ -n \"\${FOUND}\" ]; then
                    PGBIN=\$(dirname \${FOUND})
                    echo \"Found initdb at: \${PGBIN}/initdb\"
                else
                    echo 'ERROR: initdb not found anywhere'
                    exit 1
                fi
            fi

            echo '--- Initializing database cluster ---'
            chown postgres:postgres \${PGDATA}
            su -m postgres -c \"\${PGBIN}/initdb -D \${PGDATA} -U postgres --no-locale -E UTF8\"

            echo '--- Configuring for testing ---'
            cat > \${PGDATA}/pg_hba.conf << 'HBAEOF'
local   all   all                 trust
host    all   all   127.0.0.1/32  trust
host    all   all   ::1/128       trust
HBAEOF
            chown postgres:postgres \${PGDATA}/pg_hba.conf

            cat >> \${PGDATA}/postgresql.conf << 'CONFEOF'
listen_addresses = 'localhost'
unix_socket_directories = '/tmp'
shared_preload_libraries = 'pg_stat_statements'
pg_stat_statements.track = all
log_destination = 'stderr'
logging_collector = off
CONFEOF
            chown postgres:postgres \${PGDATA}/postgresql.conf

            echo '--- Starting PostgreSQL ---'
            su -m postgres -c \"\${PGBIN}/pg_ctl -D \${PGDATA} -l /tmp/pg.log start\"
            su -m postgres -c \"\${PGBIN}/pg_isready -h /tmp -U postgres\"
        " 2>&1 | tee "$test_output/logs/init-start.log"

        # Wait for PG to be ready
        local max_attempts=30 attempt=0
        log_info "Waiting for PostgreSQL to be ready..."
        while [ $attempt -lt $max_attempts ]; do
            if docker exec "$container_name" \
                su -m postgres -c "$pgbin/pg_isready -h /tmp -U postgres" &>/dev/null; then
                log_success "PostgreSQL is ready"
                break
            fi
            attempt=$((attempt + 1))
            sleep 1
        done
        if [ $attempt -ge $max_attempts ]; then
            log_error "PostgreSQL did not become ready within ${max_attempts}s"
            docker exec "$container_name" cat /tmp/pg.log 2>/dev/null || true
            exit 1
        fi
        echo ""
    fi

    # ── Phase: check ──────────────────────────────────────────────────────
    if $run_check; then
        log_info "═══ Phase: check — Installation Health Checks ═══"
        echo ""

        local check_log="$test_output/install-checks.log"
        local checks_passed=0 checks_failed=0

        _run_check() {
            local desc="$1"
            local sql="$2"
            log_info "  $desc"
            if docker exec "$container_name" \
                su -m postgres -c "$pgbin/psql -h /tmp -U postgres -tAc \"$sql\"" >> "$check_log" 2>&1; then
                log_success "  $desc"
                checks_passed=$((checks_passed + 1))
            else
                log_error "  $desc"
                checks_failed=$((checks_failed + 1))
            fi
        }

        _run_check "PostgreSQL version" "SELECT version();"
        _run_check "Accepting connections" "SELECT 1;"
        _run_check "Data directory" "SHOW data_directory;"
        _run_check "Shared memory" "SHOW shared_buffers;"
        _run_check "WAL configuration" "SHOW wal_level;"
        _run_check "Template databases" "SELECT count(*) FROM pg_database WHERE datistemplate;"
        _run_check "System catalogs" "SELECT count(*) FROM pg_class;"
        _run_check "pg_stat_activity" "SELECT count(*) FROM pg_stat_activity;"

        echo ""
        log_info "Installation checks: $checks_passed passed, $checks_failed failed"
        echo ""
    fi

    # ── Phase: sql ────────────────────────────────────────────────────────
    if $run_sql; then
        log_info "═══ Phase: sql — SQL Test Suite ═══"
        echo ""

        local sql_test_dir="${PROJECT_ROOT}/tests/sql"
        local sql_runner_args=()
        sql_runner_args+=(--host /tmp)
        sql_runner_args+=(--port 5432)
        sql_runner_args+=(--dbname postgres)
        sql_runner_args+=(--user postgres)
        sql_runner_args+=(--output /tmp/sql-results)

        if [[ -n "$ARG_FILTER" ]]; then
            sql_runner_args+=(--filter "$ARG_FILTER")
        fi
        if [[ -n "$ARG_CATEGORY" ]]; then
            sql_runner_args+=(--category "$ARG_CATEGORY")
        fi
        if [[ -n "$ARG_SQL_STOP_ON_FAILURE" ]]; then
            sql_runner_args+=(--stop-on-failure)
        fi
        if [[ -n "$ARG_SQL_LIST" ]]; then
            sql_runner_args+=(--list)
        fi

        # Copy test files into container
        docker exec "$container_name" mkdir -p /tmp/sql-tests /tmp/sql-results
        docker exec "$container_name" chown -R postgres:postgres /tmp/sql-tests /tmp/sql-results

        for f in "$sql_test_dir"/[0-9]*.sql; do
            [ -f "$f" ] || continue
            docker cp "$f" "$container_name:/tmp/sql-tests/"
        done
        docker cp "$sql_test_dir/run-sql-tests.sh" "$container_name:/tmp/sql-tests/"
        docker exec "$container_name" bash -c "chmod +x /tmp/sql-tests/run-sql-tests.sh && chown -R postgres:postgres /tmp/sql-tests"

        if docker exec "$container_name" \
            su -m postgres -c "export PATH=${pgbin}:\$PATH && /tmp/sql-tests/run-sql-tests.sh ${sql_runner_args[*]}" 2>&1 | \
            tee "$test_output/sql-tests.log"; then
            log_success "SQL test suite passed"
            SQL_OK=1
            docker cp "$container_name:/tmp/sql-results/." "$test_output/sql-results/" 2>/dev/null || true
        else
            log_error "SQL test suite had failures"
            docker cp "$container_name:/tmp/sql-results/." "$test_output/sql-results/" 2>/dev/null || true
        fi
        echo ""
    fi

    # ── Final Summary ─────────────────────────────────────────────────────
    echo ""
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║     Test Summary                                            ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo ""

    log_info "Distro:     $distro ($pkg_type)"
    log_info "PG Version: $pg_major"
    log_info "Phases:     $phases"
    log_info "Container:  $container_name"
    echo ""

    local any_failed=false
    if $run_build || $run_install; then
        if [[ "$BUILD_OK" -eq 1 ]] || [[ "$INSTALL_OK" -eq 1 ]]; then
            log_success "Build/Install: OK"
        else
            log_error "Build/Install: FAILED"
            any_failed=true
        fi
    fi
    if $run_init; then
        log_success "Init & Start:  OK"
    fi
    if $run_sql; then
        if [[ "$SQL_OK" -eq 1 ]]; then
            log_success "SQL Tests:     OK"
        else
            log_error "SQL Tests:     FAILED"
            any_failed=true
        fi
    fi

    echo ""
    log_info "Logs: $test_output/logs/"

    cat > "$test_output/summary.txt" << EOF
PostgreSQL Installation & SQL Test Results
==========================================
Date: $(date -u +"%Y-%m-%d %H:%M:%S UTC")
Distribution: $distro ($pkg_type)
PG Version: $pg_major
Phases: $phases
$(if [[ -n "$pkg_dir" ]]; then echo "Packages: $pkg_dir (pre-built)"; else echo "Packages: built from source"; fi)
$(if [[ -n "$ARG_FILTER" ]]; then echo "SQL Filter: $ARG_FILTER"; fi)
$(if [[ -n "$ARG_CATEGORY" ]]; then echo "SQL Category: $ARG_CATEGORY"; fi)

Build/Install: $([ "$BUILD_OK" -eq 1 ] || [ "$INSTALL_OK" -eq 1 ] && echo "PASS" || echo "SKIP/FAIL")
SQL Tests:     $([ "$SQL_OK" -eq 1 ] && echo "PASS" || echo "SKIP/FAIL")
EOF

    if $any_failed; then
        return 1
    fi

    log_success "All executed phases passed!"
    return 0
}

# ─── Command: test-sql ────────────────────────────────────────────────────
#
# Run SQL test suite against a running PostgreSQL instance (standalone).
# Does not build or install anything — connects to an existing PG instance.
#
# Flags:
#   --pg-host HOST       PostgreSQL host (default: /tmp)
#   --pg-port PORT       PostgreSQL port (default: 5432)
#   --pg-user USER       PostgreSQL user (default: postgres)
#   --pg-dbname DB       Database name (default: postgres)
#   --filter PATTERN     Test filter pattern (e.g., "01_*")
#   --category CAT       Test category filter
#   --sql-stop-on-failure Stop at first failure
#   --sql-list           List tests without running

cmd_test_sql() {
    local sql_runner="${PROJECT_ROOT}/tests/sql/run-sql-tests.sh"

    if [[ ! -x "$sql_runner" ]]; then
        log_error "SQL test runner not found: $sql_runner"
        exit 1
    fi

    local args=()
    args+=(--host "${ARG_PG_HOST:-/tmp}")
    args+=(--port "${ARG_PG_PORT:-5432}")
    args+=(--user "${ARG_PG_USER:-postgres}")
    args+=(--dbname "${ARG_PG_DBNAME:-postgres}")

    if [[ -n "$ARG_FILTER" ]]; then
        args+=(--filter "$ARG_FILTER")
    fi
    if [[ -n "$ARG_CATEGORY" ]]; then
        args+=(--category "$ARG_CATEGORY")
    fi
    if [[ -n "$ARG_SQL_STOP_ON_FAILURE" ]]; then
        args+=(--stop-on-failure)
    fi
    if [[ -n "$ARG_SQL_LIST" ]]; then
        args+=(--list)
    fi

    local out_dir="${OUTPUT_BASE}/test-output/sql"
    args+=(--output "$out_dir")

    exec "$sql_runner" "${args[@]}"
}

# ─── Usage ─────────────────────────────────────────────────────────────────

usage() {
    cat <<'EOF'
Unified Build Environment & Local Test for PostgreSQL Packaging

Usage: build-env.sh <command> [options]

Build Commands:
  build-rpm       Build an RPM package in the selected environment
  build-deb       Build a DEB package in the selected environment
  build-all-rpm   Build RPM matrix from pipeline.conf (filterable with flags)
  build-all-deb   Build DEB matrix from pipeline.conf (filterable with flags)

Environment Commands:
  check           Verify build environment prerequisites
  setup           Initialize build environment (Docker images, chroots)
  shell           Open interactive shell in build environment
  clean           Clean build environment resources
  list-builders   List available build environments and their status
  status          Show current configuration and output layout

Test Commands:
  test-env        Test build environment for distributions (image + deps check)
  test-install    Full build-install-test cycle with phase-level control
  test-quick      Quick Dockerfile-only validation (no env tests)
  test-sql        Run SQL test suite against a running PostgreSQL instance

Build Options:
  --builder=NAME     Build environment: docker, mock, pbuilder, direct
  --package=NAME     Package name (e.g., postgresql-17)
  --distro=DIST      Target distribution (e.g., EL-9, bookworm, el9, all, rpm, deb)
  --pg-major=VER     PostgreSQL major version (e.g., 17)
  --pg-full=VER      Full version (e.g., 17.7)
  --pg-release=REL   Release number (e.g., 1)
  --output=DIR       Output base directory (default: ./output)
  --no-cache         Rebuild without cache (Docker setup)
  --stop-on-error    Stop the build sequence on first failure (build-all-rpm)

Test Options:
  --phase=PHASES     Comma-separated phases for test-install:
                       env,build,install,init,check,sql  (or "all", default: all)
  --filter=PATTERN   SQL test filter pattern (e.g., "01_*", "03_*")
  --category=CAT     SQL test category (core, extensions, performance)
  --pkg-dir=DIR      Use pre-built packages (skip build phase in test-install)
  --pkg-type=TYPE    Package type override: rpm or deb (auto-detected from distro)
  --keep             Keep test containers after completion
  --no-cleanup       Don't clean up test Docker images
  --sql-stop-on-failure  Stop SQL tests at first failure
  --sql-list         List available SQL tests without running them
  --dry-run          Show what would be done without executing

Standalone SQL Test Options (test-sql):
  --pg-host=HOST     PostgreSQL host (default: /tmp)
  --pg-port=PORT     PostgreSQL port (default: 5432)
  --pg-user=USER     PostgreSQL user (default: postgres)
  --pg-dbname=DB     Database name (default: postgres)

Build Environments:
  docker        RPM + DEB  — Docker containers (default, most isolated)
  docker-sbuild DEB only   — Docker + sbuild + mmdebstrap (isolated)
  mmdebstrap    DEB only   — mmdebstrap + sbuild (5-10x faster DEBs)
  sbuild        DEB only   — Traditional sbuild + debootstrap
  mock          RPM only   — Mock chroot (standard Fedora/EPEL tool)
  pbuilder      DEB only   — pbuilder/cowbuilder (Debian/Ubuntu chroot)
  direct        RPM + DEB  — Local host, no isolation (fastest)

RPM Build Examples:
  # Build postgresql-17 RPM for EL-9 (Docker, default)
  build-env.sh build-rpm --package postgresql-17 --distro EL-9 \
      --pg-major 17 --pg-full 17.7 --pg-release 1

  # Build postgresql-16 RPM for EL-8 with Mock
  build-env.sh build-rpm --builder mock --package postgresql-16 \
      --distro EL-8 --pg-major 16 --pg-full 16.6 --pg-release 1

  # Build ALL RPM combinations from pipeline.conf
  build-env.sh build-all-rpm

  # Build PG17 across all RPM distros (EL-8, EL-9, EL-10, Fedora)
  build-env.sh build-all-rpm --pg-major 17

  # Build all PG versions for EL-9 only
  build-env.sh build-all-rpm --distro EL-9

  # Build PG17 × EL-9 only, stop on first error
  build-env.sh build-all-rpm --pg-major 17 --distro EL-9 --stop-on-error

DEB Build Examples:
  # Build postgresql-17 DEB for Debian bookworm (Docker, default)
  build-env.sh build-deb --package postgresql-17 --distro bookworm \
      --pg-major 17 --pg-full 17.7 --pg-release 1

  # Build postgresql-16 DEB for Ubuntu Noble with pbuilder
  build-env.sh build-deb --builder pbuilder --package postgresql-16 \
      --distro noble --pg-major 16 --pg-full 16.6 --pg-release 1

  # Build ALL DEB combinations from pipeline.conf
  build-env.sh build-all-deb

  # Build PG16 DEBs across all Debian/Ubuntu distros
  build-env.sh build-all-deb --pg-major 16

  # Build all PG versions for Ubuntu Jammy only
  build-env.sh build-all-deb --distro jammy

Test Examples:
  # Test build environment for all distros
  build-env.sh test-env

  # Test build environment for a single distro
  build-env.sh test-env --distro el9

  # Quick Dockerfile validation only
  build-env.sh test-quick --distro rpm

  # Full install+SQL test cycle (all phases)
  build-env.sh test-install --distro el9 --pg-major 17

  # Run only build and install phases
  build-env.sh test-install --distro el9 --phase build,install

  # Run only SQL tests phase (assumes PG already running in container)
  build-env.sh test-install --distro el9 --phase env,init,sql

  # Use pre-built packages instead of building from source
  build-env.sh test-install --distro el9 --pkg-dir ./output/RPMS

  # Run SQL tests with filter
  build-env.sh test-install --distro debian-bookworm --filter "01_*"

  # Run only core category SQL tests
  build-env.sh test-install --distro el9 --category core

  # Dry run: show what would happen
  build-env.sh test-install --distro el9 --dry-run

  # Standalone SQL tests against a running PG instance
  build-env.sh test-sql --pg-host localhost --pg-port 5432

  # List available SQL tests
  build-env.sh test-sql --sql-list

Output Structure:
  output/
  ├── builds/<builder>/<distro>/<package>/{RPMS,SRPMS,DEBS}
  ├── repos/{rpm,deb}/<distro>/...
  ├── logs/<builder>/<distro>/<package>-<timestamp>.log
  └── test-output/
      ├── logs/                     Test build & env logs
      ├── results/summary.txt       Environment test results
      ├── install-sql/              Install test output
      │   ├── logs/                 Build/install/init logs
      │   ├── sql-results/          SQL test output
      │   └── summary.txt
      └── sql/                      Standalone SQL test output

Configuration:
  Set BUILD_ENV in pipeline.conf to change the default builder.
  See docs/LOCAL_BUILD_AND_TEST.md for the complete guide.
EOF
}

# ─── Main ──────────────────────────────────────────────────────────────────

parse_args "$@"

case "${COMMAND}" in
    build-rpm)      cmd_build_rpm ;;
    build-deb)      cmd_build_deb ;;
    build-all-rpm)  cmd_build_all_rpm ;;
    build-all-deb)  cmd_build_all_deb ;;
    check)          cmd_check ;;
    setup)          cmd_setup ;;
    shell)          cmd_shell ;;
    clean)          cmd_clean ;;
    list-builders)  cmd_list_builders ;;
    status)         cmd_status ;;
    # ── Test commands ────────────────────────────────────────────────
    test-env)       cmd_test_env ;;
    test-quick)     cmd_test_quick ;;
    test-install)   cmd_test_install ;;
    test-sql)       cmd_test_sql ;;
    -h|--help|help) usage ;;
    "")             usage; exit 0 ;;
    *)
        log_error "Unknown command: ${COMMAND}"
        echo ""
        usage
        exit 1
        ;;
esac
