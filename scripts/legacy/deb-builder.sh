#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# deb-builder.sh — DEB package build orchestrator
# ─────────────────────────────────────────────────────────────────────────────
#
# Comprehensive DEB package building for PostgreSQL across all Debian/Ubuntu
# distributions. Supports Docker and pbuilder build environments.
#
# Usage:
#   ./deb-builder.sh build [OPTIONS]
#   ./deb-builder.sh test [OPTIONS]
#   ./deb-builder.sh lint [OPTIONS]
#   ./deb-builder.sh clean [OPTIONS]
#
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
OUTPUT_DIR="${OUTPUT_DIR:-$PROJECT_ROOT/output}"
BUILD_ENV="${BUILD_ENV:-docker}"
DEB_BUILDER="${DEB_BUILDER:-docker}"
PARALLEL_JOBS="${PARALLEL_JOBS:-4}"

# Logging
log_info() { echo -e "${BLUE}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[✓]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[✗]${NC} $*"; }

# ─── Source Configuration ─────────────────────────────────────────────────────
source_config() {
    if [[ -f "$PROJECT_ROOT/pipeline.conf" ]]; then
        source "$PROJECT_ROOT/pipeline.conf"
    fi
    
    if [[ -f "$PROJECT_ROOT/configs/build-targets.yaml" ]]; then
        # YAML parsing would go here - for now using pipeline.conf
        :
    fi
}

# ─── Extract DEB targets from configuration ───────────────────────────────────
get_deb_targets() {
    local enabled_only="${1:-1}"
    
    if [[ -z "${DEB_BUILD_TARGETS[@]:-}" ]]; then
        log_error "DEB_BUILD_TARGETS not configured in pipeline.conf"
        return 1
    fi
    
    for target in "${DEB_BUILD_TARGETS[@]}"; do
        IFS=':' read -r distro docker_image enabled <<< "$target"
        
        if [[ "$enabled_only" -eq 1 && "$enabled" -eq 0 ]]; then
            continue
        fi
        
        echo "$distro:$docker_image:$enabled"
    done
}

# ─── Build DEB package ─────────────────────────────────────────────────────────
build_deb() {
    local distro="$1"
    local source_dir="$2"
    local output_dir="${3:-.}"
    
    log_info "Building DEB for distribution: $distro"
    
    # Determine builder image
    local builder_image=""
    for target in $(get_deb_targets 0); do
        IFS=':' read -r dist image enabled <<< "$target"
        if [[ "$dist" == "$distro" ]]; then
            builder_image="$image"
            break
        fi
    done
    
    if [[ -z "$builder_image" ]]; then
        log_error "No builder image found for distribution: $distro"
        return 1
    fi
    
    case "$DEB_BUILDER" in
        docker)
            build_deb_docker "$distro" "$builder_image" "$source_dir" "$output_dir"
            ;;
        pbuilder)
            build_deb_pbuilder "$distro" "$source_dir" "$output_dir"
            ;;
        *)
            log_error "Unknown DEB builder: $DEB_BUILDER"
            return 1
            ;;
    esac
}

# ─── Build using Docker ──────────────────────────────────────────────────────
build_deb_docker() {
    local distro="$1"
    local docker_image="$2"
    local source_dir="$3"
    local output_dir="$4"
    
    local full_image="${DOCKER_IMAGE_PREFIX:-postgresql-build}:${docker_image}"
    local build_output="$output_dir/builds/docker/$distro"
    
    log_info "Building with Docker image: $full_image"
    
    mkdir -p "$build_output/DEBS"
    
    # Build Docker image if needed
    local dockerfile="$PROJECT_ROOT/docker/${docker_image}/Dockerfile"
    if [[ ! -f "$dockerfile" ]]; then
        log_error "Dockerfile not found: $dockerfile"
        return 1
    fi
    
    docker build -t "$full_image" -f "$dockerfile" "$PROJECT_ROOT/docker/${docker_image}"
    
    # Run build in container
    docker run --rm \
        -v "$source_dir:/home/builder/packaging:ro" \
        -v "$build_output:/home/builder/output" \
        "$full_image" \
        bash -c 'cd /home/builder/packaging && debuild -us -uc'
    
    log_success "DEB build completed for $distro"
}

# ─── Build using pbuilder ────────────────────────────────────────────────────
build_deb_pbuilder() {
    local distro="$1"
    local source_dir="$2"
    local output_dir="$3"
    
    log_info "Building with pbuilder for $distro"
    
    local pbuilder_base="${PBUILDER_BASE:-/var/cache/pbuilder}"
    local pbuild_dir="$pbuilder_base/$distro"
    
    # Create or update pbuilder chroot
    if [[ ! -d "$pbuild_dir/base.tgz" ]]; then
        log_info "Creating pbuilder chroot for $distro..."
        sudo pbuilder create \
            --basetgz "$pbuild_dir/base.tgz" \
            --distribution "$distro" \
            --mirror "http://deb.debian.org/debian" \
            --debootstrapopts "--variant=buildd"
    fi
    
    # Run build
    local build_output="$output_dir/builds/pbuilder/$distro"
    mkdir -p "$build_output"
    
    sudo pbuilder build \
        --basetgz "$pbuild_dir/base.tgz" \
        --buildresult "$build_output" \
        "$source_dir"/*.dsc
    
    log_success "DEB build completed for $distro"
}

# ─── Run lintian validation ──────────────────────────────────────────────────
lint_deb() {
    local deb_dir="$1"
    local output_file="${2:-lintian-report.txt}"
    
    log_info "Running lintian validation..."
    
    if ! command -v lintian &> /dev/null; then
        log_error "lintian not found. Install with: sudo apt-get install lintian"
        return 1
    fi
    
    > "$output_file"
    local total_issues=0
    
    for deb in "$deb_dir"/*.deb; do
        [[ -f "$deb" ]] || continue
        
        log_info "Checking: $(basename "$deb")"
        
        if lintian -i "$deb" >> "$output_file" 2>&1; then
            log_success "✓ $(basename "$deb") - No issues"
        else
            local issues=$(grep -c "^" "$output_file" || echo 0)
            log_warn "⚠ $(basename "$deb") - $issues issues found"
            ((total_issues++))
        fi
    done
    
    if [[ $total_issues -eq 0 ]]; then
        log_success "All packages passed lintian validation"
        return 0
    else
        log_warn "$total_issues packages have lintian warnings"
        return 1
    fi
}

# ─── Build all DEB distributions ──────────────────────────────────────────────
build_all_deb() {
    local source_dir="$1"
    
    log_info "Building DEB packages for all enabled distributions..."
    
    local distros=()
    for target in $(get_deb_targets 1); do
        IFS=':' read -r distro _ _ <<< "$target"
        distros+=("$distro")
    done
    
    local success_count=0
    local fail_count=0
    
    for distro in "${distros[@]}"; do
        if build_deb "$distro" "$source_dir" "$OUTPUT_DIR"; then
            ((success_count++))
        else
            ((fail_count++))
        fi
    done
    
    log_success "DEB build summary: $success_count succeeded, $fail_count failed"
    return $([[ $fail_count -eq 0 ]] && echo 0 || echo 1)
}

# ─── Clean build artifacts ───────────────────────────────────────────────────
clean_deb() {
    local distro="${1:-}"
    
    if [[ -z "$distro" ]]; then
        log_info "Cleaning all DEB build artifacts..."
        rm -rf "$OUTPUT_DIR/builds/docker"/*
        rm -rf "$OUTPUT_DIR/builds/pbuilder"/*
        rm -rf "$OUTPUT_DIR/repos/deb"/*
    else
        log_info "Cleaning DEB artifacts for $distro..."
        rm -rf "$OUTPUT_DIR/builds/docker/$distro"
        rm -rf "$OUTPUT_DIR/builds/pbuilder/$distro"
        rm -rf "$OUTPUT_DIR/repos/deb/$distro"
    fi
    
    log_success "Cleanup completed"
}

# ─── Show help ────────────────────────────────────────────────────────────────
show_help() {
    cat << 'HELP'
PostgreSQL DEB Package Builder

USAGE:
  deb-builder.sh <command> [options]

COMMANDS:
  build [DISTRO] [SOURCE_DIR]
    Build DEB packages. If DISTRO specified, build only that distribution.
    SOURCE_DIR defaults to current directory (must contain debian/ subdir)

  build-all [SOURCE_DIR]
    Build DEB packages for all enabled distributions

  lint [DEB_DIR]
    Run lintian validation on .deb files in DEB_DIR

  list-targets
    List all available DEB build targets

  clean [DISTRO]
    Remove build artifacts. If DISTRO specified, clean only that distribution

  help
    Show this help message

OPTIONS:
  --builder BUILDER       Use specified builder (docker, pbuilder) [default: docker]
  --output-dir DIR       Set output directory [default: ./output]
  --parallel N           Number of parallel jobs [default: 4]

ENVIRONMENT VARIABLES:
  BUILD_ENV              Build environment (docker, pbuilder) [default: docker]
  DEB_BUILDER            DEB builder tool (docker, pbuilder) [default: docker]
  OUTPUT_DIR             Output directory [default: ./output]
  DOCKER_IMAGE_PREFIX    Docker image prefix [default: postgresql-build]

EXAMPLES:
  # Build for all distributions
  ./deb-builder.sh build-all /path/to/postgresql-source

  # Build for specific distribution
  ./deb-builder.sh build bookworm /path/to/postgresql-source

  # Validate built packages
  ./deb-builder.sh lint output/builds/docker/bookworm/DEBS

  # Clean artifacts
  ./deb-builder.sh clean

HELP
}

# ─── Main command dispatcher ──────────────────────────────────────────────────
main() {
    local command="${1:-help}"
    shift || true
    
    source_config
    
    case "$command" in
        build)
            if [[ $# -lt 1 ]]; then
                log_error "build requires at least source directory argument"
                echo "Usage: deb-builder.sh build [DISTRO] <SOURCE_DIR>"
                return 1
            fi
            
            if [[ $# -eq 2 ]]; then
                build_deb "$1" "$2" "$OUTPUT_DIR"
            else
                # Build all distributions
                build_deb "bookworm" "$1" "$OUTPUT_DIR"
            fi
            ;;
        
        build-all)
            if [[ $# -lt 1 ]]; then
                log_error "build-all requires source directory argument"
                return 1
            fi
            build_all_deb "$1"
            ;;
        
        lint)
            if [[ $# -lt 1 ]]; then
                log_error "lint requires directory argument"
                return 1
            fi
            lint_deb "$1"
            ;;
        
        list-targets)
            log_info "Available DEB build targets:"
            get_deb_targets 0 | column -t -s':'
            ;;
        
        clean)
            clean_deb "$@"
            ;;
        
        help|--help|-h)
            show_help
            ;;
        
        *)
            log_error "Unknown command: $command"
            show_help
            return 1
            ;;
    esac
}

# Execute main
main "$@"
