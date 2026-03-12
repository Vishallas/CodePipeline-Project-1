#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────
# test-sbuild-setup.sh — Comprehensive sbuild setup validation
# ─────────────────────────────────────────────────────────────────────────
# Tests sbuild environment for PostgreSQL package building
#
# Usage:
#   ./scripts/test-sbuild-setup.sh [--quick] [--distro DISTRO]
#
# ─────────────────────────────────────────────────────────────────────────

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Counters
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_SKIPPED=0

# ═════════════════════════════════════════════════════════════════════════
# TEST FRAMEWORK
# ═════════════════════════════════════════════════════════════════════════

test_start() {
    echo -e "\n${BLUE}[TEST]${NC} $*"
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
    echo -e "\n${BLUE}════════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}$*${NC}"
    echo -e "${BLUE}════════════════════════════════════════════════════════════════${NC}\n"
}

# ═════════════════════════════════════════════════════════════════════════
# TESTS
# ═════════════════════════════════════════════════════════════════════════

test_root_access() {
    test_start "Checking root/sudo access"
    if [[ $EUID -eq 0 ]]; then
        test_pass "Running as root"
    else
        test_skip "Not root (sbuild may not need sudo for actual builds)"
    fi
}

test_distro() {
    test_start "Checking system distribution"
    if [[ -f /etc/os-release ]]; then
        # Use subshell to avoid variable pollution
        local distro=$(bash -c 'source /etc/os-release && echo "$PRETTY_NAME"')
        test_pass "System: $distro"
    else
        test_fail "Cannot determine system distribution"
    fi
}

test_sbuild_installed() {
    test_start "Checking sbuild installation"
    if command -v sbuild &>/dev/null; then
        local version=$(sbuild --version 2>/dev/null | head -1)
        test_pass "sbuild installed: $version"
    else
        test_fail "sbuild not found (run: sudo apt-get install sbuild)"
    fi
}

test_schroot_installed() {
    test_start "Checking schroot installation"
    if command -v schroot &>/dev/null; then
        local version=$(schroot --version 2>/dev/null | head -1)
        test_pass "schroot installed: $version"
    else
        test_fail "schroot not found (run: sudo apt-get install schroot)"
    fi
}

test_debootstrap_installed() {
    test_start "Checking debootstrap installation"
    if command -v debootstrap &>/dev/null; then
        test_pass "debootstrap installed"
    else
        test_fail "debootstrap not found"
    fi
}

test_mmdebstrap_installed() {
    test_start "Checking mmdebstrap installation"
    if command -v mmdebstrap &>/dev/null; then
        test_pass "mmdebstrap installed (fast chroot creation available)"
    else
        test_skip "mmdebstrap not found (optional, debootstrap will be used)"
    fi
}

test_ccache_available() {
    test_start "Checking ccache availability"
    if command -v ccache &>/dev/null; then
        local version=$(ccache --version 2>/dev/null | head -1)
        test_pass "ccache available: $version"
    else
        test_skip "ccache not installed (optional, builds will be slower)"
    fi
}

test_eatmydata_available() {
    test_start "Checking eatmydata availability"
    if command -v eatmydata &>/dev/null; then
        test_pass "eatmydata available (I/O acceleration)"
    else
        test_skip "eatmydata not installed (optional, builds will be slower)"
    fi
}

test_build_tools() {
    test_start "Checking build tools"
    local missing=()
    for tool in fakeroot devscripts dpkg-dev; do
        if command -v "$tool" &>/dev/null || dpkg -l | grep -q "^ii  $tool"; then
            test_pass "Found: $tool"
        else
            missing+=("$tool")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        test_fail "Missing tools: ${missing[*]}"
    fi
}

test_sbuild_config() {
    test_start "Checking sbuild configuration"
    if [[ -f "$HOME/.sbuildrc" ]]; then
        test_pass "sbuildrc found: $HOME/.sbuildrc"

        # Check key settings
        if grep -q 'use_ccache' "$HOME/.sbuildrc"; then
            test_pass "ccache enabled in sbuildrc"
        fi
    else
        test_skip "No sbuildrc found (will be created on first setup)"
    fi
}

test_sbuild_base_dir() {
    test_start "Checking sbuild base directory"
    if [[ -d "/var/lib/sbuild" ]]; then
        local size=$(du -sh /var/lib/sbuild 2>/dev/null | cut -f1)
        test_pass "sbuild base exists: /var/lib/sbuild (size: $size)"
    else
        test_skip "sbuild base directory not yet created (will be created on init)"
    fi
}

test_schroot_configs() {
    test_start "Checking schroot configurations"
    if [[ -d "/etc/schroot/chroot.d" ]]; then
        local count=$(ls -1 /etc/schroot/chroot.d/ 2>/dev/null | wc -l)
        if [[ $count -gt 0 ]]; then
            test_pass "Found $count schroot configurations"
            ls -1 /etc/schroot/chroot.d/ | sed 's/^/  - /'
        else
            test_skip "No schroot configurations found (will be created on init)"
        fi
    else
        test_skip "schroot config directory not yet created"
    fi
}

test_chroots_exist() {
    test_start "Checking existing chroots"
    if [[ -d "/var/lib/sbuild" ]]; then
        local chroots=($(find /var/lib/sbuild -maxdepth 1 -type d -name "*-*-sbuild" 2>/dev/null | sort))
        if [[ ${#chroots[@]} -gt 0 ]]; then
            test_pass "Found ${#chroots[@]} chroots"
            for chroot in "${chroots[@]}"; do
                local size=$(du -sh "$chroot" 2>/dev/null | cut -f1)
                echo "  - $(basename "$chroot") ($size)"
            done
        else
            test_skip "No chroots initialized yet (run: sudo ./scripts/sbuild-setup.sh init)"
        fi
    fi
}

test_chroot_functionality() {
    local distro="${1:-bookworm}"
    test_start "Testing chroot functionality: $distro"

    local chroot_id="${distro}-amd64-sbuild"

    if ! schroot -l 2>/dev/null | grep -q "$chroot_id"; then
        test_skip "Chroot not available: $chroot_id"
        return
    fi

    # Test schroot session
    if schroot -c "$chroot_id" -u root -- echo "Chroot test" &>/dev/null; then
        test_pass "Chroot session successful: $chroot_id"
    else
        test_fail "Cannot create chroot session: $chroot_id"
    fi

    # Test apt inside chroot
    if schroot -c "$chroot_id" -u root -- apt-get --version &>/dev/null; then
        test_pass "apt working in chroot: $chroot_id"
    else
        test_fail "apt not working in chroot: $chroot_id"
    fi

    # Test build tools in chroot
    if schroot -c "$chroot_id" -u root -- dpkg-dev --version &>/dev/null; then
        test_pass "Build tools available in chroot: $chroot_id"
    else
        test_fail "Build tools not available in chroot: $chroot_id"
    fi
}

test_disk_space() {
    test_start "Checking disk space"
    local available=$(df /var/lib/sbuild 2>/dev/null | tail -1 | awk '{print $4}')
    local required=$((20 * 1024 * 1024))  # 20 GB in KB

    if [[ -z "$available" ]]; then
        test_skip "Could not determine disk space"
        return
    fi

    available=$((available / 1024))  # Convert to GB
    required=$((required / 1024))

    if [[ $available -gt $required ]]; then
        test_pass "Sufficient disk space: ${available}GB available (need ${required}GB)"
    else
        test_fail "Insufficient disk space: ${available}GB available, need ${required}GB"
    fi
}

test_build_env_script() {
    test_start "Checking build-env.sh script"
    if [[ -f "scripts/build-env.sh" ]]; then
        if [[ -x "scripts/build-env.sh" ]]; then
            test_pass "build-env.sh found and executable"
        else
            test_fail "build-env.sh found but not executable"
        fi
    else
        test_fail "build-env.sh not found"
    fi
}

test_sbuild_setup_script() {
    test_start "Checking sbuild-setup.sh script"
    if [[ -f "scripts/sbuild-setup.sh" ]]; then
        if [[ -x "scripts/sbuild-setup.sh" ]]; then
            test_pass "sbuild-setup.sh found and executable"
        else
            test_fail "sbuild-setup.sh found but not executable"
        fi
    else
        test_fail "sbuild-setup.sh not found"
    fi
}

test_documentation() {
    test_start "Checking documentation"
    if [[ -f "docs/sbuild-enterprise-guide.md" ]]; then
        test_pass "sbuild enterprise guide found"
    else
        test_fail "sbuild enterprise guide not found"
    fi

    if [[ -f "docs/SBUILD_QUICK_REFERENCE.md" ]]; then
        test_pass "sbuild quick reference found"
    else
        test_fail "sbuild quick reference not found"
    fi
}

# ═════════════════════════════════════════════════════════════════════════
# MAIN TEST RUNNER
# ═════════════════════════════════════════════════════════════════════════

run_all_tests() {
    test_section "sbuild Environment Validation Tests"

    echo "System and Prerequisites:"
    test_root_access
    test_distro
    test_disk_space

    echo -e "\nPackage Installation:"
    test_sbuild_installed
    test_schroot_installed
    test_debootstrap_installed
    test_mmdebstrap_installed
    test_ccache_available
    test_eatmydata_available
    test_build_tools

    echo -e "\nConfiguration:"
    test_sbuild_config
    test_sbuild_base_dir
    test_schroot_configs

    echo -e "\nProject Files:"
    test_sbuild_setup_script
    test_build_env_script
    test_documentation

    echo -e "\nChroot Status:"
    test_chroots_exist

    # Test specific chroot if available
    if [[ -d "/var/lib/sbuild" ]]; then
        local available_chroots=($(find /var/lib/sbuild -maxdepth 1 -type d -name "*-*-sbuild" 2>/dev/null | sort))
        if [[ ${#available_chroots[@]} -gt 0 ]]; then
            echo -e "\nChroot Functionality Tests:"
            # Test first available chroot
            local first_chroot=$(basename "${available_chroots[0]}" | sed 's/-amd64-sbuild//')
            test_chroot_functionality "$first_chroot"
        fi
    fi
}

print_summary() {
    echo -e "\n${BLUE}════════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}Test Summary${NC}"
    echo -e "${BLUE}════════════════════════════════════════════════════════════════${NC}\n"

    echo -e "Passed:  ${GREEN}$TESTS_PASSED${NC}"
    echo -e "Failed:  ${RED}$TESTS_FAILED${NC}"
    echo -e "Skipped: ${YELLOW}$TESTS_SKIPPED${NC}"
    echo -e "Total:   $((TESTS_PASSED + TESTS_FAILED + TESTS_SKIPPED))\n"

    if [[ $TESTS_FAILED -eq 0 ]]; then
        echo -e "${GREEN}✓ All critical tests passed!${NC}\n"

        echo "Next steps:"
        echo "  1. If chroots not initialized:"
        echo "     sudo ./scripts/sbuild-setup.sh init"
        echo ""
        echo "  2. Verify installation:"
        echo "     ./scripts/sbuild-setup.sh list"
        echo ""
        echo "  3. Build a package:"
        echo "     sbuild -d bookworm-amd64-sbuild postgresql-17_17.8-1.dsc"
        echo ""

        return 0
    else
        echo -e "${RED}✗ Some tests failed. Review output above.${NC}\n"
        return 1
    fi
}

# ═════════════════════════════════════════════════════════════════════════
# MAIN
# ═════════════════════════════════════════════════════════════════════════

main() {
    # Change to project directory
    if [[ ! -d "scripts" ]]; then
        echo -e "${RED}Error: Must be run from project root directory${NC}"
        exit 1
    fi

    run_all_tests
    print_summary
}

main "$@"
