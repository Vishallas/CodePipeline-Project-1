#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# build-deb.sh — Simple DEB builder for PostgreSQL packages (local machine)
# ─────────────────────────────────────────────────────────────────────────────
#
# This is a convenience script for building Debian packages on your local machine
# using sbuild + mmdebstrap. For more advanced builds or build matrix operations,
# use ./scripts/build-env.sh instead.
#
# Usage:
#   ./scripts/build-deb.sh <distro> <pg-major> [pg-full] [pg-release]
#
# Examples:
#   # Build PostgreSQL 17 for Debian bookworm
#   ./scripts/build-deb.sh bookworm 17
#
#   # Build PostgreSQL 16.8 release 1 for Ubuntu jammy
#   ./scripts/build-deb.sh jammy 16 16.8 1
#
#   # Build all supported PostgreSQL versions for bookworm
#   for pgver in 14 15 16 17 18; do
#     ./scripts/build-deb.sh bookworm $pgver
#   done
#
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info()    { echo -e "${BLUE}[INFO]${NC}    $*"; }
log_success() { echo -e "${GREEN}[✓]${NC}      $*"; }
log_error()   { echo -e "${RED}[✗]${NC}      $*"; }
log_step()    { echo -e "${CYAN}[STEP]${NC}    $*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "${SCRIPT_DIR}")"

# ─── Parameters ─────────────────────────────────────────────────────────────

DISTRO="${1:-}"
PG_MAJOR="${2:-}"
PG_FULL="${3:-}"
PG_RELEASE="${4:-1}"
rc=0

# ─── Validation ─────────────────────────────────────────────────────────────

if [[ -z "$DISTRO" ]] || [[ -z "$PG_MAJOR" ]]; then
    cat << USAGE
${CYAN}PostgreSQL DEB Builder${NC}

Simple wrapper around sbuild + mmdebstrap for local machine builds.

Usage:
  ${CYAN}$0 <distro> <pg-major> [pg-full] [pg-release]${NC}

Parameters:
  distro       - Debian/Ubuntu distribution (bookworm, bullseye, jammy, noble, focal)
  pg-major     - PostgreSQL major version (14, 15, 16, 17, 18)
  pg-full      - Full version number (default: \${pg-major}.0)
  pg-release   - Release number (default: 1)

Examples:
  ${CYAN}$0 bookworm 17${NC}
    → Build PostgreSQL 17.0-1 for Debian bookworm

  ${CYAN}$0 jammy 16 16.8 1${NC}
    → Build PostgreSQL 16.8-1 for Ubuntu jammy

Advanced (build all versions):
  ${CYAN}for v in 14 15 16 17 18; do $0 bookworm \$v; done${NC}

For build matrix operations, use:
  ${CYAN}./scripts/build-env.sh build-all-deb${NC}

USAGE
    exit 1
fi

# Default to X.0 if not specified
if [[ -z "$PG_FULL" ]]; then
    PG_FULL="${PG_MAJOR}.0"
fi

PACKAGE="postgresql-${PG_MAJOR}"

echo ""
echo "╔═══════════════════════════════════════════════════════════════════╗"
echo "║  PostgreSQL DEB Builder (sbuild + mmdebstrap)                    ║"
echo "╚═══════════════════════════════════════════════════════════════════╝"
echo ""
log_info "Package:       ${PACKAGE}"
log_info "Distribution:  ${DISTRO}"
log_info "PostgreSQL:    ${PG_MAJOR} (${PG_FULL}-${PG_RELEASE})"
log_info "Output:        ${PROJECT_ROOT}/output"
echo ""

# ─── Validation ─────────────────────────────────────────────────────────────

log_step "Validating environment..."

# Check for build-env.sh
if [[ ! -f "${SCRIPT_DIR}/build-env.sh" ]]; then
    log_error "build-env.sh not found: ${SCRIPT_DIR}/build-env.sh"
    exit 1
fi

# Validate distro
case "$DISTRO" in
    bookworm|bullseye|trixie|sid|jammy|noble|focal)
        log_success "Distribution: ${DISTRO}"
        ;;
    *)
        log_error "Unsupported distribution: ${DISTRO}"
        log_error "Supported: bookworm, bullseye, trixie, sid, jammy, noble, focal"
        exit 1
        ;;
esac

# Validate PostgreSQL major version
if ! [[ "$PG_MAJOR" =~ ^[0-9]+$ ]] || [[ $PG_MAJOR -lt 10 ]]; then
    log_error "Invalid PostgreSQL major version: ${PG_MAJOR}"
    exit 1
fi
log_success "PostgreSQL version: ${PG_MAJOR}"

# Check for mmdebstrap/sbuild
if ! command -v sbuild &>/dev/null; then
    log_error "sbuild not found. Install with: sudo apt install sbuild"
    exit 1
fi
log_success "sbuild available"

if ! command -v mmdebstrap &>/dev/null; then
    log_error "mmdebstrap not found. Install with: sudo apt install mmdebstrap"
    exit 1
fi
log_success "mmdebstrap available"

echo ""

# ─── Build ──────────────────────────────────────────────────────────────────

log_step "Starting DEB build via build-env.sh..."
echo ""

# Use the existing build-env.sh infrastructure
"${SCRIPT_DIR}/build-env.sh" build-deb \
    --builder mmdebstrap \
    --package "$PACKAGE" \
    --distro "$DISTRO" \
    --pg-major "$PG_MAJOR" \
    --pg-full "$PG_FULL" \
    --pg-release "$PG_RELEASE"

rc=$?

echo ""
if [[ $rc -eq 0 ]]; then
    log_success "Build completed successfully!"
    echo ""
    log_info "Output directory:"
    log_info "  ${PROJECT_ROOT}/output/builds/mmdebstrap/${DISTRO}/${PACKAGE}/"
    echo ""
    log_info "To list build artifacts:"
    log_info "  ls -lh output/builds/mmdebstrap/${DISTRO}/${PACKAGE}/DEBS/"
    echo ""
else
    log_error "Build failed (see logs above)"
    echo ""
    log_info "Check build log:"
    log_info "  ls -lhtr output/logs/mmdebstrap/${DISTRO}/ | tail -1"
    exit 1
fi
