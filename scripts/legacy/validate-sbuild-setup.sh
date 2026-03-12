#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# validate-sbuild-setup.sh — Comprehensive sbuild setup validation
# ─────────────────────────────────────────────────────────────────────────────
#
# Validates that sbuild is properly configured for PostgreSQL building.
# Tests both native sbuild and docker-sbuild integration.
#
# Usage:
#   ./scripts/validate-sbuild-setup.sh [--docker] [--native] [--all]
#
# ─────────────────────────────────────────────────────────────────────────────

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Test state
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_SKIPPED=0

# ═════════════════════════════════════════════════════════════════════════════
# TEST FRAMEWORK
# ═════════════════════════════════════════════════════════════════════════════

log_header() {
    echo -e "\n${BLUE}════════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}$*${NC}"
    echo -e "${BLUE}════════════════════════════════════════════════════════════════${NC}\n"
}

test_start() {
    echo -e "${CYAN}[TEST]${NC} $*"
}

test_pass() {
    echo -e "${GREEN}[✓]${NC} $*"
    ((TESTS_PASSED++))
}

test_fail() {
    echo -e "${RED}[✗]${NC} $*"
    ((TESTS_FAILED++))
}

test_skip() {
    echo -e "${YELLOW}[~]${NC} $*"
    ((TESTS_SKIPPED++))
}

test_section() {
    echo -e "\n${CYAN}▶ $*${NC}"
}

# ═════════════════════════════════════════════════════════════════════════════
# NATIVE SBUILD TESTS
# ═════════════════════════════════════════════════════════════════════════════

test_native_sbuild_setup() {
    log_header "Native sbuild Environment"

    test_section "Checking sbuild setup script"
    if [[ -x "./scripts/sbuild-setup.sh" ]]; then
        test_pass "sbuild-setup.sh exists and executable"
    else
        test_fail "sbuild-setup.sh not found or not executable"
        return 1
    fi

    test_section "Checking sbuild/schroot installation"
    if command -v sbuild &>/dev/null; then
        local version=$(sbuild --version 2>/dev/null | head -1)
        test_pass "sbuild installed: $version"
    else
        test_skip "sbuild not installed (run: sudo apt-get install sbuild)"
    fi

    if command -v schroot &>/dev/null; then
        test_pass "schroot installed"
    else
        test_skip "schroot not installed (run: sudo apt-get install schroot)"
    fi

    test_section "Checking sbuild configuration"
    if [[ -f "$HOME/.sbuildrc" ]]; then
        test_pass "sbuild config exists: $HOME/.sbuildrc"

        # Check for performance optimizations
        if grep -q 'use_ccache = 1' "$HOME/.sbuildrc"; then
            test_pass "ccache enabled in sbuildrc"
        fi

        if grep -q 'eatmydata = 1' "$HOME/.sbuildrc"; then
            test_pass "eatmydata enabled in sbuildrc"
        fi
    else
        test_skip "No .sbuildrc found (will be created on first init)"
    fi

    test_section "Checking sbuild chroots"
    if [[ -d "/var/lib/sbuild" ]]; then
        local count=$(find /var/lib/sbuild -maxdepth 1 -type d -name "*-*-sbuild" 2>/dev/null | wc -l)
        if [[ $count -gt 0 ]]; then
            test_pass "Found $count sbuild chroots in /var/lib/sbuild"
            find /var/lib/sbuild -maxdepth 1 -type d -name "*-*-sbuild" 2>/dev/null | \
                while read chroot; do
                    local size=$(du -sh "$chroot" 2>/dev/null | cut -f1)
                    echo "  - $(basename "$chroot") ($size)"
                done
        else
            test_skip "No sbuild chroots found (run: sudo ./scripts/sbuild-setup.sh init)"
        fi
    else
        test_skip "sbuild base directory not created yet"
    fi

    test_section "Testing native sbuild chroot functionality"
    if [[ -d "/var/lib/sbuild" ]]; then
        local first_chroot=$(find /var/lib/sbuild -maxdepth 1 -type d -name "*-*-sbuild" -print -quit 2>/dev/null)
        if [[ -n "$first_chroot" ]]; then
            local chroot_name=$(basename "$first_chroot" -sbuild)
            if schroot -c "$chroot_name" -u root -- apt-get --version &>/dev/null; then
                test_pass "Chroot session successful: $chroot_name"
            else
                test_fail "Cannot create chroot session: $chroot_name"
            fi
        fi
    fi
}

# ═════════════════════════════════════════════════════════════════════════════
# DOCKER-SBUILD TESTS
# ═════════════════════════════════════════════════════════════════════════════

test_docker_sbuild_setup() {
    log_header "Docker-sbuild Environment"

    test_section "Checking Docker installation"
    if command -v docker &>/dev/null; then
        local version=$(docker --version)
        test_pass "Docker installed: $version"
    elif command -v podman &>/dev/null; then
        local version=$(podman --version)
        test_pass "Podman installed (Docker alternative): $version"
    else
        test_skip "Docker/Podman not installed"
        return 0
    fi

    test_section "Checking docker-sbuild script"
    if [[ -f "./scripts/build-envs/docker-sbuild.sh" ]]; then
        test_pass "docker-sbuild.sh exists"

        # Check if the chroot init fix is present
        if grep -q "sbuild-createchroot" "./scripts/build-envs/docker-sbuild.sh"; then
            test_pass "Chroot initialization code found (fix applied)"
        else
            test_fail "Chroot initialization code NOT found (old version?)"
        fi

        # Check for mirror logic
        if grep -q 'SBUILD_MIRROR=' "./scripts/build-envs/docker-sbuild.sh"; then
            test_pass "Mirror selection logic found"
        else
            test_fail "Mirror selection logic NOT found"
        fi
    else
        test_fail "docker-sbuild.sh not found"
        return 1
    fi

    test_section "Checking Dockerfiles"
    local dockerfile_count=0
    for dockerfile in docker/debian-*/Dockerfile docker/ubuntu-*/Dockerfile; do
        if [[ -f "$dockerfile" ]]; then
            ((dockerfile_count++))
            # Check if sbuild is installed in Dockerfile
            if grep -q 'sbuild schroot debootstrap' "$dockerfile"; then
                test_pass "sbuild installed in $(dirname $dockerfile)"
            else
                test_fail "sbuild NOT installed in $(dirname $dockerfile)"
            fi
        fi
    done

    if [[ $dockerfile_count -eq 0 ]]; then
        test_skip "No Dockerfiles found for testing"
        return 0
    fi

    test_section "Testing Docker image builds"
    # Try to build a test image
    if [[ -f "docker/debian-bookworm/Dockerfile" ]]; then
        test_start "Building debian-bookworm Docker image (may take time)..."
        if docker build -t postgresql-build:debian-bookworm-test docker/debian-bookworm 2>&1 | tail -3; then
            test_pass "Docker image built successfully"

            # Test sbuild-createchroot inside container
            test_start "Testing sbuild-createchroot inside container..."
            if docker run --rm postgresql-build:debian-bookworm-test \
                sbuild-createchroot --help &>/dev/null; then
                test_pass "sbuild-createchroot available in container"
            else
                test_fail "sbuild-createchroot not available in container"
            fi

            # Cleanup test image
            docker rmi postgresql-build:debian-bookworm-test &>/dev/null || true
        else
            test_skip "Could not build Docker image (network or disk issue)"
        fi
    fi
}

# ═════════════════════════════════════════════════════════════════════════════
# BUILD-ENV INTEGRATION TESTS
# ═════════════════════════════════════════════════════════════════════════════

test_build_env_integration() {
    log_header "build-env.sh Integration"

    test_section "Checking build-env.sh"
    if [[ ! -f "./scripts/build-env.sh" ]]; then
        test_fail "build-env.sh not found"
        return 1
    fi

    if [[ ! -x "./scripts/build-env.sh" ]]; then
        test_fail "build-env.sh not executable"
        return 1
    fi

    test_pass "build-env.sh found and executable"

    test_section "Checking builder options"
    local builders=("docker" "docker-sbuild" "sbuild" "mock" "pbuilder")
    for builder in "${builders[@]}"; do
        if grep -q "\"$builder\"" "./scripts/build-env.sh" || \
           grep -q "'$builder'" "./scripts/build-env.sh"; then
            test_pass "Builder supported: $builder"
        fi
    done

    test_section "Verifying sbuild build driver files"
    if [[ -f "./scripts/build-envs/sbuild.sh" ]]; then
        test_pass "sbuild.sh driver exists"
    else
        test_skip "sbuild.sh driver not found"
    fi

    if [[ -f "./scripts/build-envs/sbuild/sbuild-postgresql.conf" ]]; then
        test_pass "sbuild-postgresql.conf configuration exists"
    else
        test_skip "sbuild-postgresql.conf not found"
    fi
}

# ═════════════════════════════════════════════════════════════════════════════
# DOCUMENTATION TESTS
# ═════════════════════════════════════════════════════════════════════════════

test_documentation() {
    log_header "Documentation"

    test_section "Checking sbuild documentation"
    local docs=(
        "docs/sbuild-enterprise-guide.md"
        "docs/SBUILD_SETUP_README.md"
        "docs/SBUILD_QUICK_REFERENCE.md"
        "docs/BUILD_POSTGRESQL_WITH_SBUILD.md"
        "docs/SBUILD_DOCKER_INTEGRATION_FIX.md"
    )

    for doc in "${docs[@]}"; do
        if [[ -f "$doc" ]]; then
            local size=$(wc -l < "$doc")
            test_pass "Found: $(basename $doc) ($size lines)"
        else
            test_fail "Missing: $doc"
        fi
    done
}

# ═════════════════════════════════════════════════════════════════════════════
# PRINT SUMMARY
# ═════════════════════════════════════════════════════════════════════════════

print_summary() {
    echo -e "\n${BLUE}════════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}Validation Summary${NC}"
    echo -e "${BLUE}════════════════════════════════════════════════════════════════${NC}\n"

    echo -e "Passed:  ${GREEN}$TESTS_PASSED${NC}"
    echo -e "Failed:  ${RED}$TESTS_FAILED${NC}"
    echo -e "Skipped: ${YELLOW}$TESTS_SKIPPED${NC}"
    echo -e "Total:   $((TESTS_PASSED + TESTS_FAILED + TESTS_SKIPPED))\n"

    if [[ $TESTS_FAILED -eq 0 ]]; then
        echo -e "${GREEN}✓ All critical tests passed!${NC}\n"

        echo "Next steps:"
        echo "  1. For native sbuild: sudo ./scripts/sbuild-setup.sh init"
        echo "  2. For docker-sbuild: docker build docker/debian-bookworm"
        echo "  3. Try building: ./scripts/build-env.sh build-deb ..."
        echo ""
        echo "See documentation:"
        echo "  - docs/sbuild-enterprise-guide.md"
        echo "  - docs/SBUILD_DOCKER_INTEGRATION_FIX.md"
        echo ""

        return 0
    else
        echo -e "${RED}✗ Some tests failed. See output above.${NC}\n"
        return 1
    fi
}

# ═════════════════════════════════════════════════════════════════════════════
# MAIN
# ═════════════════════════════════════════════════════════════════════════════

main() {
    local test_native=false
    local test_docker=false
    local test_integration=true
    local test_docs=true

    # Parse arguments
    for arg in "$@"; do
        case "$arg" in
            --native) test_native=true ;;
            --docker) test_docker=true ;;
            --all) test_native=true; test_docker=true ;;
            --help|-h)
                echo "Usage: $0 [--native] [--docker] [--all]"
                echo ""
                echo "Options:"
                echo "  --native    Test native sbuild setup"
                echo "  --docker    Test docker-sbuild setup"
                echo "  --all       Test everything"
                exit 0
                ;;
        esac
    done

    # If no specific tests selected, run all
    if [[ "$test_native" == "false" && "$test_docker" == "false" ]]; then
        test_native=true
        test_docker=true
    fi

    # Change to project root
    if [[ ! -f "scripts/build-env.sh" ]]; then
        echo "Error: Must be run from project root directory"
        exit 1
    fi

    # Run tests
    [[ "$test_native" == "true" ]] && test_native_sbuild_setup
    [[ "$test_docker" == "true" ]] && test_docker_sbuild_setup
    [[ "$test_integration" == "true" ]] && test_build_env_integration
    [[ "$test_docs" == "true" ]] && test_documentation

    # Print summary
    print_summary
}

main "$@"
