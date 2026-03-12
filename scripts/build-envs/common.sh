#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# common.sh — Shared utilities for all build environment drivers
# ─────────────────────────────────────────────────────────────────────────────
#
# This file is sourced by each build environment driver. It provides:
#   - Logging helpers
#   - Output directory management (segregated folder structure)
#   - Common validation routines
#   - Build artifact collection
#
# ─────────────────────────────────────────────────────────────────────────────

# Prevent double-sourcing
[[ -n "${_BUILD_ENV_COMMON_LOADED:-}" ]] && return 0
_BUILD_ENV_COMMON_LOADED=1

# ─── Paths ─────────────────────────────────────────────────────────────────

BUILDENV_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILDENV_PROJECT_ROOT="$(dirname "$(dirname "${BUILDENV_SCRIPT_DIR}")")"

# ─── Colors ────────────────────────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# ─── Logging ───────────────────────────────────────────────────────────────

_log_ts() { date '+%Y-%m-%d %H:%M:%S'; }

log_info()    { echo -e "${BLUE}[$(_log_ts)] [INFO]${NC}    $*" >&2; }
log_success() { echo -e "${GREEN}[$(_log_ts)] [OK]${NC}      $*" >&2; }
log_warn()    { echo -e "${YELLOW}[$(_log_ts)] [WARN]${NC}    $*" >&2; }
log_error()   { echo -e "${RED}[$(_log_ts)] [ERROR]${NC}   $*" >&2; }
log_step()    { echo -e "${CYAN}[$(_log_ts)] [STEP]${NC}    $*" >&2; }
log_build()   { echo -e "${BOLD}[$(_log_ts)] [BUILD]${NC}   $*" >&2; }

# ─── Output Directory Structure ────────────────────────────────────────────
#
# Segregated output layout:
#
#   output/
#   ├── builds/
#   │   └── <builder>/                    docker | mock | pbuilder | direct
#   │       └── <distro>/                 EL-9, bookworm, etc.
#   │           └── <package>/            postgresql-17, pg_stat_monitor, etc.
#   │               ├── RPMS/
#   │               │   ├── x86_64/
#   │               │   ├── aarch64/
#   │               │   └── noarch/
#   │               ├── SRPMS/
#   │               └── DEBS/
#   ├── repos/
#   │   ├── rpm/
#   │   │   └── <distro>/<arch>/
#   │   └── deb/
#   │       └── <dist>/pool/main/
#   └── logs/
#       └── <builder>/<distro>/<package>-<timestamp>.log
#
# ─────────────────────────────────────────────────────────────────────────────

# Initialize the segregated output directory tree for a build.
# Usage: init_build_output <builder> <distro> <package> [base_output_dir]
init_build_output() {
    local builder="$1"
    local distro="$2"
    local package="$3"
    local base_dir="${4:-${BUILDENV_PROJECT_ROOT}/output}"

    local build_dir="${base_dir}/builds/${builder}/${distro}/${package}"

    mkdir -p "${build_dir}/RPMS/x86_64"
    mkdir -p "${build_dir}/RPMS/aarch64"
    mkdir -p "${build_dir}/RPMS/noarch"
    mkdir -p "${build_dir}/SRPMS"
    mkdir -p "${build_dir}/DEBS"
    mkdir -p "${base_dir}/logs/${builder}/${distro}"

    echo "${build_dir}"
}

# Return the log file path for this build.
# Usage: get_build_log <builder> <distro> <package> [base_output_dir]
get_build_log() {
    local builder="$1"
    local distro="$2"
    local package="$3"
    local base_dir="${4:-${BUILDENV_PROJECT_ROOT}/output}"
    local ts
    ts=$(date '+%Y%m%d-%H%M%S')

    echo "${base_dir}/logs/${builder}/${distro}/${package}-${ts}.log"
}

# Organize built RPMs into the repo layout.
# Usage: organize_rpm_output <build_dir> <distro> [base_output_dir]
organize_rpm_output() {
    local build_dir="$1"
    local distro="$2"
    local base_dir="${3:-${BUILDENV_PROJECT_ROOT}/output}"
    local repo_dir="${base_dir}/repos/rpm/${distro}"

    local rpm_file arch dest
    for rpm_file in "${build_dir}"/RPMS/*/*.rpm "${build_dir}"/RPMS/*.rpm; do
        [[ -f "$rpm_file" ]] || continue
        arch=$(rpm -qp --queryformat '%{ARCH}' "$rpm_file" 2>/dev/null || basename "$(dirname "$rpm_file")")
        dest="${repo_dir}/${arch}"
        mkdir -p "${dest}"
        cp -p "$rpm_file" "${dest}/"
        log_info "Repo: $(basename "$rpm_file") -> repos/rpm/${distro}/${arch}/"
    done

    for srpm_file in "${build_dir}"/SRPMS/*.src.rpm; do
        [[ -f "$srpm_file" ]] || continue
        mkdir -p "${repo_dir}/SRPMS"
        cp -p "$srpm_file" "${repo_dir}/SRPMS/"
        log_info "Repo: $(basename "$srpm_file") -> repos/rpm/${distro}/SRPMS/"
    done
}

# Organize built DEBs into the repo layout.
# Usage: organize_deb_output <build_dir> <dist> [base_output_dir]
organize_deb_output() {
    local build_dir="$1"
    local dist="$2"
    local base_dir="${3:-${BUILDENV_PROJECT_ROOT}/output}"
    local repo_dir="${base_dir}/repos/deb/${dist}"

    local deb_file pkg_name first_letter pool_dir
    for deb_file in "${build_dir}"/DEBS/*.deb; do
        [[ -f "$deb_file" ]] || continue
        pkg_name=$(dpkg-deb -f "$deb_file" Package 2>/dev/null || basename "$deb_file" .deb | cut -d_ -f1)
        first_letter="${pkg_name:0:1}"
        pool_dir="${repo_dir}/pool/main/${first_letter}/${pkg_name}"
        mkdir -p "${pool_dir}"
        cp -p "$deb_file" "${pool_dir}/"
        log_info "Repo: $(basename "$deb_file") -> repos/deb/${dist}/pool/main/${first_letter}/${pkg_name}/"
    done
}

# Print a summary of what's in a build output directory.
# Usage: summarize_build_output <build_dir>
summarize_build_output() {
    local build_dir="$1"

    local rpm_count=0 srpm_count=0 deb_count=0
    rpm_count=$(find "${build_dir}/RPMS" -name '*.rpm' 2>/dev/null | wc -l)
    srpm_count=$(find "${build_dir}/SRPMS" -name '*.src.rpm' 2>/dev/null | wc -l)
    deb_count=$(find "${build_dir}/DEBS" -name '*.deb' 2>/dev/null | wc -l)

    echo ""
    echo "  Build artifacts in: ${build_dir}"
    echo "  ──────────────────────────────────────"
    echo "    Binary RPMs:  ${rpm_count}"
    echo "    Source RPMs:  ${srpm_count}"
    echo "    DEBs:         ${deb_count}"
    echo ""
}

# ─── Validation ────────────────────────────────────────────────────────────

# Check that a builder type is valid.
# Usage: validate_builder <builder>
validate_builder() {
    local builder="$1"
    case "$builder" in
        docker|docker-sbuild|mock|pbuilder|direct|sbuild|mmdebstrap) return 0 ;;
        *)
            log_error "Invalid build environment: '${builder}'"
            log_error "Supported: docker, docker-sbuild, mock, pbuilder, direct, sbuild, mmdebstrap"
            return 1
            ;;
    esac
}

# Convert a builder name to a valid bash function prefix.
# This handles builder names with hyphens (e.g., docker-sbuild -> docker_sbuild)
# Usage: get_builder_function_prefix <builder>
get_builder_function_prefix() {
    local builder="$1"
    echo "${builder//-/_}"
}

# Check if a command exists.
# Usage: require_command <cmd> <friendly_name>
require_command() {
    local cmd="$1"
    local name="${2:-$1}"
    if ! command -v "$cmd" &>/dev/null; then
        log_error "${name} is required but not found. Install it first."
        return 1
    fi
}

# ─── Builder Registration ─────────────────────────────────────────────────
#
# Each driver script must register these functions:
#   builder_<name>_check_deps     — verify prerequisites
#   builder_<name>_build_rpm      — build an RPM package
#   builder_<name>_build_deb      — build a DEB package
#   builder_<name>_shell          — open interactive shell (optional)
#   builder_<name>_clean          — cleanup resources (optional)
#
# ─────────────────────────────────────────────────────────────────────────────
