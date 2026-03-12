#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# pbuilder-setup.sh — pbuilder/cowbuilder environment configuration
# ─────────────────────────────────────────────────────────────────────────────
#
# Sets up and manages pbuilder and cowbuilder chroots for efficient Debian
# package building. Supports all configured Debian/Ubuntu distributions.
#
# Usage:
#   ./pbuilder-setup.sh init [DISTRO ...]    # Create pbuilder chroots
#   ./pbuilder-setup.sh update [DISTRO ...]  # Update existing chroots
#   ./pbuilder-setup.sh list                 # List all pbuilder chroots
#   ./pbuilder-setup.sh clean [DISTRO ...]   # Remove chroots
#
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

# Configuration
PBUILDER_BASE="${PBUILDER_BASE:-/var/cache/pbuilder}"
DEBIAN_MIRROR="${DEBIAN_MIRROR:-http://deb.debian.org/debian}"
UBUNTU_MIRROR="${UBUNTU_MIRROR:-http://archive.ubuntu.com/ubuntu}"
SECURITY_MIRROR="${SECURITY_MIRROR:-http://security.debian.org/debian-security}"
PREFER_COWBUILDER="${PREFER_COWBUILDER:-true}"

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[✓]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[✗]${NC} $*"; }

# ─── Check prerequisites ──────────────────────────────────────────────────────
check_prerequisites() {
    log_info "Checking prerequisites..."
    
    if ! command -v pbuilder &> /dev/null; then
        log_error "pbuilder not found. Install with: sudo apt-get install pbuilder"
        return 1
    fi
    
    if [[ "$PREFER_COWBUILDER" == "true" ]]; then
        if ! command -v cowbuilder &> /dev/null; then
            log_warn "cowbuilder not found. Install with: sudo apt-get install cowbuilder"
            log_info "Falling back to pbuilder"
            PREFER_COWBUILDER="false"
        fi
    fi
    
    if ! command -v debootstrap &> /dev/null; then
        log_error "debootstrap not found. Install with: sudo apt-get install debootstrap"
        return 1
    fi
    
    if [[ ! -d "$PBUILDER_BASE" ]]; then
        log_info "Creating pbuilder base directory: $PBUILDER_BASE"
        sudo mkdir -p "$PBUILDER_BASE"
    fi
    
    if [[ ! -w "$PBUILDER_BASE" ]]; then
        log_error "pbuilder base directory not writable: $PBUILDER_BASE"
        log_info "Try: sudo usermod -a -G pbuilder $USER"
        return 1
    fi
    
    log_success "Prerequisites check passed"
    return 0
}

# ─── Get mirror for distribution ──────────────────────────────────────────────
get_mirror() {
    local distro="$1"
    
    case "$distro" in
        bookworm|bullseye|trixie|sid)
            echo "$DEBIAN_MIRROR"
            ;;
        noble|jammy|mantic|oracular|focal)
            echo "$UBUNTU_MIRROR"
            ;;
        *)
            echo "$DEBIAN_MIRROR"
            ;;
    esac
}

# ─── Get security mirror for distribution ──────────────────────────────────────
get_security_mirror() {
    local distro="$1"
    
    case "$distro" in
        bookworm|bullseye|trixie|sid)
            echo "$SECURITY_MIRROR"
            ;;
        *)
            echo "http://security.ubuntu.com/ubuntu"
            ;;
    esac
}

# ─── Initialize pbuilder chroot ───────────────────────────────────────────────
init_pbuilder() {
    local distro="$1"
    local mirror=$(get_mirror "$distro")
    
    log_info "Initializing pbuilder chroot for $distro (mirror: $mirror)..."
    
    local base_tgz="$PBUILDER_BASE/$distro-base.tgz"
    
    if [[ -f "$base_tgz" ]]; then
        log_warn "Chroot already exists: $base_tgz"
        read -p "Overwrite? (y/N) " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            return 0
        fi
        sudo rm -f "$base_tgz"
    fi
    
    local debootstrap_opts="--variant=buildd"
    
    # Use cowbuilder if available and preferred
    if [[ "$PREFER_COWBUILDER" == "true" ]]; then
        log_info "Using cowbuilder (COW mode)..."
        sudo cowbuilder --create \
            --basepath "$PBUILDER_BASE/$distro-base" \
            --distribution "$distro" \
            --mirror "$mirror" \
            --debootstrapopts "$debootstrap_opts"
    else
        sudo pbuilder create \
            --basetgz "$base_tgz" \
            --distribution "$distro" \
            --mirror "$mirror" \
            --debootstrapopts "$debootstrap_opts" \
            --components "main contrib non-free"
    fi
    
    log_success "Pbuilder chroot initialized for $distro"
}

# ─── Update pbuilder chroot ───────────────────────────────────────────────────
update_pbuilder() {
    local distro="$1"
    
    log_info "Updating pbuilder chroot for $distro..."
    
    local base_tgz="$PBUILDER_BASE/$distro-base.tgz"
    
    if [[ ! -f "$base_tgz" ]]; then
        log_error "Chroot does not exist: $base_tgz"
        return 1
    fi
    
    if [[ "$PREFER_COWBUILDER" == "true" ]]; then
        sudo cowbuilder --update \
            --basepath "$PBUILDER_BASE/$distro-base"
    else
        sudo pbuilder update \
            --basetgz "$base_tgz"
    fi
    
    log_success "Pbuilder chroot updated for $distro"
}

# ─── List pbuilder chroots ───────────────────────────────────────────────────
list_chroots() {
    log_info "Available pbuilder chroots:"
    
    if [[ ! -d "$PBUILDER_BASE" ]]; then
        log_warn "No pbuilder base directory found: $PBUILDER_BASE"
        return 0
    fi
    
    local found=0
    for base_tgz in "$PBUILDER_BASE"/*-base.tgz; do
        if [[ -f "$base_tgz" ]]; then
            local distro=$(basename "$base_tgz" -base.tgz)
            local size=$(du -h "$base_tgz" | cut -f1)
            local modified=$(stat -c '%y' "$base_tgz" | cut -d' ' -f1)
            
            printf "  %-20s %6s  (updated: %s)\n" "$distro" "$size" "$modified"
            ((found++))
        fi
    done
    
    # Also check for cowbuilder COW bases
    if [[ -d "$PBUILDER_BASE" ]]; then
        for cow_base in "$PBUILDER_BASE"/*-base; do
            if [[ -d "$cow_base" && ! -d "$PBUILDER_BASE/${cow_base##*/}-base.tgz" ]]; then
                local distro=$(basename "$cow_base" -base)
                local modified=$(stat -c '%y' "$cow_base" | cut -d' ' -f1)
                
                printf "  %-20s (COW)   (updated: %s)\n" "$distro" "$modified"
                ((found++))
            fi
        done
    fi
    
    if [[ $found -eq 0 ]]; then
        log_warn "No pbuilder chroots found"
    fi
}

# ─── Clean pbuilder chroots ───────────────────────────────────────────────────
clean_chroot() {
    local distro="${1:-}"
    
    if [[ -z "$distro" ]]; then
        log_warn "Cleaning ALL pbuilder chroots"
        read -p "Are you sure? (y/N) " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            return 0
        fi
        
        sudo rm -rf "$PBUILDER_BASE"/*
        log_success "All chroots removed"
    else
        log_info "Removing chroot for $distro..."
        
        sudo rm -f "$PBUILDER_BASE/$distro-base.tgz"
        sudo rm -rf "$PBUILDER_BASE/$distro-base"
        
        log_success "Chroot removed for $distro"
    fi
}

# ─── Show help ────────────────────────────────────────────────────────────────
show_help() {
    cat << 'HELP'
pbuilder/cowbuilder Chroot Manager

USAGE:
  pbuilder-setup.sh <command> [DISTRO ...]

COMMANDS:
  init [DISTRO ...]       Create pbuilder chroots for specified distributions
  update [DISTRO ...]     Update existing chroots
  list                    List all available chroots
  clean [DISTRO ...]      Remove chroots
  check                   Check prerequisites
  help                    Show this help message

ARGUMENTS:
  DISTRO                  Debian/Ubuntu distribution codename
                          (bookworm, bullseye, noble, jammy, focal, etc.)
                          If omitted in init/update, uses all configured distributions

ENVIRONMENT VARIABLES:
  PBUILDER_BASE           Base directory for pbuilder chroots
                          [default: /var/cache/pbuilder]
  DEBIAN_MIRROR           Debian mirror URL
                          [default: http://deb.debian.org/debian]
  UBUNTU_MIRROR           Ubuntu mirror URL
                          [default: http://archive.ubuntu.com/ubuntu]
  PREFER_COWBUILDER       Use cowbuilder (copy-on-write) if available
                          [default: true]

EXAMPLES:
  # Initialize chroots for all distributions
  ./pbuilder-setup.sh init

  # Initialize chroot for specific distribution
  ./pbuilder-setup.sh init bookworm noble

  # Update existing chroots
  ./pbuilder-setup.sh update bookworm jammy

  # List all chroots
  ./pbuilder-setup.sh list

  # Remove chroot
  ./pbuilder-setup.sh clean bookworm

REQUIREMENTS:
  sudo access (for chroot operations)
  pbuilder or cowbuilder installed
  debootstrap installed

NOTES:
  - First-time setup may take 10-20 minutes per distribution
  - Chroots require 2-4 GB disk space each
  - Update periodically to minimize build times
  - COW mode (cowbuilder) recommended for faster builds

HELP
}

# ─── Main command dispatcher ──────────────────────────────────────────────────
main() {
    local command="${1:-help}"
    shift || true
    
    # Check prerequisites first
    if [[ "$command" != "help" && "$command" != "--help" && "$command" != "-h" ]]; then
        check_prerequisites || return 1
    fi
    
    case "$command" in
        init)
            if [[ $# -eq 0 ]]; then
                log_info "Initializing default distributions: bookworm, trixie, bullseye, noble, jammy, focal"
                for distro in bookworm trixie bullseye noble jammy focal; do
                    init_pbuilder "$distro" || true
                done
            else
                for distro in "$@"; do
                    init_pbuilder "$distro" || true
                done
            fi
            ;;
        
        update)
            if [[ $# -eq 0 ]]; then
                log_info "Updating all existing chroots..."
                for base_tgz in "$PBUILDER_BASE"/*-base.tgz; do
                    if [[ -f "$base_tgz" ]]; then
                        local distro=$(basename "$base_tgz" -base.tgz)
                        update_pbuilder "$distro" || true
                    fi
                done
            else
                for distro in "$@"; do
                    update_pbuilder "$distro" || true
                done
            fi
            ;;
        
        list)
            list_chroots
            ;;
        
        clean)
            if [[ $# -eq 0 ]]; then
                clean_chroot
            else
                for distro in "$@"; do
                    clean_chroot "$distro" || true
                done
            fi
            ;;
        
        check)
            check_prerequisites
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

main "$@"
