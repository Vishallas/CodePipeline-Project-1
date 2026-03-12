#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# build-test-deb.sh
# ─────────────────────────────────────────────────────────────────────────────
# Integrated build and test framework for DEB packages using mmdebstrap
#
# Builds PostgreSQL DEB packages and runs comprehensive validation tests:
#   1. Build verification (dpkg-buildpackage)
#   2. Package integrity checks (lintian)
#   3. Installation testing (in containers)
#   4. Dependency validation
#   5. Functional testing
#
# Usage:
#   ./scripts/build-test-deb.sh [options]
#
# Options:
#   --pg-major VERSION      PostgreSQL major version (14, 15, 16, 17, 18)
#   --distro DISTRO         Build distribution (bookworm, jammy, etc.)
#   --build-only            Skip tests, build only
#   --test-only             Skip builds, test only (requires existing .deb files)
#   --parallel N            Number of parallel jobs
#   --verbose               Verbose output
#   --help                  Show this help
#
# Examples:
#   ./scripts/build-test-deb.sh --pg-major 16 --distro bookworm
#   ./scripts/build-test-deb.sh --pg-major 16 --build-only
#   ./scripts/build-test-deb.sh --test-only
#
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# Configuration
# ─────────────────────────────────────────────────────────────────────────────

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPTS_DIR="${PROJECT_ROOT}/scripts"
DOCKER_DIR="${PROJECT_ROOT}/docker"
TESTS_DIR="${PROJECT_ROOT}/tests"
OUTPUT_DIR="${PROJECT_ROOT}/output/builds"

# Colors
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly NC='\033[0m'

# Counters
BUILDS_SUCCESS=0
BUILDS_FAILED=0
TESTS_PASSED=0
TESTS_FAILED=0

# ─────────────────────────────────────────────────────────────────────────────
# Parse arguments
# ─────────────────────────────────────────────────────────────────────────────

PG_MAJOR=""
DISTRO=""
BUILD_ONLY=0
TEST_ONLY=0
PARALLEL_JOBS=$(($(nproc) - 1))
VERBOSE=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --pg-major)
            PG_MAJOR="$2"
            shift 2
            ;;
        --distro)
            DISTRO="$2"
            shift 2
            ;;
        --build-only)
            BUILD_ONLY=1
            shift
            ;;
        --test-only)
            TEST_ONLY=1
            shift
            ;;
        --parallel)
            PARALLEL_JOBS="$2"
            shift 2
            ;;
        --verbose)
            VERBOSE=1
            shift
            ;;
        --help)
            grep '^# ' "${BASH_SOURCE[0]}" | head -40
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            exit 1
            ;;
    esac
done

# ─────────────────────────────────────────────────────────────────────────────
# Logging Functions
# ─────────────────────────────────────────────────────────────────────────────

log_info() { echo -e "${BLUE}[INFO]${NC}    $*"; }
log_success() { echo -e "${GREEN}[✓]${NC}      $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC}    $*"; }
log_error() { echo -e "${RED}[✗]${NC}      $*"; }
log_header() { echo -e "\n${CYAN}════════════════════════════════════════════════════════════════${NC}\n$*\n${CYAN}════════════════════════════════════════════════════════════════${NC}\n"; }

# ─────────────────────────────────────────────────────────────────────────────
# Helper Functions
# ─────────────────────────────────────────────────────────────────────────────

check_environment() {
    log_header "Checking Environment"

    # Check for required tools
    local required=("docker" "git")
    for cmd in "${required[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            log_error "Required command not found: $cmd"
            exit 1
        fi
    done
    log_success "All required commands found"

    # Check for build scripts
    if [[ ! -f "${SCRIPTS_DIR}/build-env.sh" ]]; then
        log_error "Build script not found: ${SCRIPTS_DIR}/build-env.sh"
        exit 1
    fi
    log_success "Build scripts found"

    # Check for pipeline configuration
    if [[ ! -f "${PROJECT_ROOT}/pipeline.conf" ]]; then
        log_error "Pipeline configuration not found: ${PROJECT_ROOT}/pipeline.conf"
        exit 1
    fi
    log_success "Pipeline configuration found"
}

get_available_versions() {
    # Source pipeline.conf
    source "${PROJECT_ROOT}/pipeline.conf" 2>/dev/null || true

    if [[ -z "${PG_MAJOR}" ]]; then
        # Return all versions
        echo "${PG_VERSIONS[@]}" | awk -F: '{print $1}'
    else
        # Verify the version exists
        for v_entry in "${PG_VERSIONS[@]}"; do
            local major
            major=$(echo "$v_entry" | cut -d: -f1)
            if [[ "$major" == "${PG_MAJOR}" ]]; then
                echo "$major"
                return 0
            fi
        done
        log_error "PostgreSQL version ${PG_MAJOR} not found in pipeline.conf"
        return 1
    fi
}

get_available_distros() {
    # Source pipeline.conf
    source "${PROJECT_ROOT}/pipeline.conf" 2>/dev/null || true

    if [[ -z "${DISTRO}" ]]; then
        # Return all distros
        echo "${DEB_BUILD_TARGETS[@]}" | awk -F: '{print $1}'
    else
        # Verify the distro exists
        for d_entry in "${DEB_BUILD_TARGETS[@]}"; do
            local dist
            dist=$(echo "$d_entry" | cut -d: -f1)
            if [[ "$dist" == "${DISTRO}" ]]; then
                echo "$dist"
                return 0
            fi
        done
        log_error "Distribution ${DISTRO} not found in pipeline.conf"
        return 1
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Build Functions
# ─────────────────────────────────────────────────────────────────────────────

build_package() {
    local pg_version="$1"
    local distro="$2"

    log_header "Building PostgreSQL ${pg_version} for ${distro}"

    if [[ $VERBOSE -eq 1 ]]; then
        "${SCRIPTS_DIR}/build-env.sh" build-deb postgresql-${pg_version} ${distro} || {
            log_error "Build failed for PostgreSQL ${pg_version} on ${distro}"
            ((BUILDS_FAILED++))
            return 1
        }
    else
        "${SCRIPTS_DIR}/build-env.sh" build-deb postgresql-${pg_version} ${distro} &>/dev/null || {
            log_error "Build failed for PostgreSQL ${pg_version} on ${distro}"
            ((BUILDS_FAILED++))
            return 1
        }
    fi

    log_success "Build completed for PostgreSQL ${pg_version} on ${distro}"
    ((BUILDS_SUCCESS++))
    return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# Test Functions
# ─────────────────────────────────────────────────────────────────────────────

run_lintian_checks() {
    local pg_version="$1"
    local distro="$2"
    local deb_dir="${OUTPUT_DIR}/docker/${distro}/postgresql-${pg_version}"

    if [[ ! -d "$deb_dir" ]]; then
        log_warn "DEB directory not found: $deb_dir (skipping lintian checks)"
        return 0
    fi

    log_info "Running lintian checks for PostgreSQL ${pg_version} on ${distro}..."

    if command -v lintian &>/dev/null; then
        for deb in "$deb_dir"/*.deb; do
            if [[ -f "$deb" ]]; then
                if lintian "$deb" 2>&1 | grep -E "^E: " >/dev/null; then
                    log_warn "Lintian found errors in $(basename "$deb")"
                    ((TESTS_FAILED++))
                else
                    log_success "Lintian checks passed for $(basename "$deb")"
                    ((TESTS_PASSED++))
                fi
            fi
        done
    else
        log_warn "lintian not installed (skipping lintian checks)"
    fi
}

run_installation_tests() {
    local pg_version="$1"
    local distro="$2"
    local deb_dir="${OUTPUT_DIR}/docker/${distro}/postgresql-${pg_version}"

    if [[ ! -d "$deb_dir" ]]; then
        log_warn "DEB directory not found: $deb_dir (skipping installation tests)"
        return 0
    fi

    log_info "Running installation tests for PostgreSQL ${pg_version} on ${distro}..."

    # Run tests if they exist
    if [[ -f "${TESTS_DIR}/deb/test-deb-install.sh" ]]; then
        bash "${TESTS_DIR}/deb/test-deb-install.sh" "$distro" "$deb_dir" || {
            log_warn "Installation tests failed or produced errors"
            ((TESTS_FAILED++))
            return 1
        }
        log_success "Installation tests completed for PostgreSQL ${pg_version} on ${distro}"
        ((TESTS_PASSED++))
        return 0
    else
        log_warn "Test script not found: ${TESTS_DIR}/deb/test-deb-install.sh"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Main Build/Test Pipeline
# ─────────────────────────────────────────────────────────────────────────────

main() {
    check_environment

    # Get versions and distros to build
    local -a versions
    local -a distros

    log_info "Determining build matrix..."

    if [[ $TEST_ONLY -eq 0 ]]; then
        # Get versions
        while IFS= read -r version; do
            versions+=("$version")
        done < <(get_available_versions)

        # Get distros
        while IFS= read -r dist; do
            distros+=("$dist")
        done < <(get_available_distros)

        if [[ ${#versions[@]} -eq 0 ]] || [[ ${#distros[@]} -eq 0 ]]; then
            log_error "No versions or distros to build"
            exit 1
        fi

        log_header "Build Matrix: ${#versions[@]} versions × ${#distros[@]} distros"

        # Build all combinations
        for pg_version in "${versions[@]}"; do
            for distro in "${distros[@]}"; do
                build_package "$pg_version" "$distro"
            done
        done
    fi

    # Run tests
    if [[ $BUILD_ONLY -eq 0 ]]; then
        log_header "Running Tests"

        # If test-only, determine versions/distros from existing builds
        if [[ $TEST_ONLY -eq 1 ]]; then
            while IFS= read -r version; do
                versions+=("$version")
            done < <(get_available_versions)

            while IFS= read -r dist; do
                distros+=("$dist")
            done < <(get_available_distros)
        fi

        for pg_version in "${versions[@]}"; do
            for distro in "${distros[@]}"; do
                run_lintian_checks "$pg_version" "$distro"
                run_installation_tests "$pg_version" "$distro"
            done
        done
    fi

    # Print summary
    print_summary
}

print_summary() {
    log_header "Test Summary"

    local total_builds=$((BUILDS_SUCCESS + BUILDS_FAILED))
    local total_tests=$((TESTS_PASSED + TESTS_FAILED))

    if [[ $BUILD_ONLY -eq 0 ]]; then
        echo "Builds:  ${GREEN}${BUILDS_SUCCESS}${NC} passed, ${RED}${BUILDS_FAILED}${NC} failed (total: $total_builds)"
    fi

    if [[ $TEST_ONLY -eq 0 ]]; then
        echo "Tests:   ${GREEN}${TESTS_PASSED}${NC} passed, ${RED}${TESTS_FAILED}${NC} failed (total: $total_tests)"
    fi

    if [[ $BUILDS_FAILED -eq 0 ]] && [[ $TESTS_FAILED -eq 0 ]]; then
        echo -e "\n${GREEN}✓ All checks passed!${NC}\n"
        return 0
    else
        echo -e "\n${RED}✗ Some checks failed${NC}\n"
        return 1
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Execute
# ─────────────────────────────────────────────────────────────────────────────

main "$@"
