#!/bin/bash
#
# init-new-pg-version.sh
#
# Initialize RPM packaging files for a new PostgreSQL major version release.
# Copies from the previous version and updates all version references,
# creates distribution symlinks, and registers in the global Makefile system.
#
# Usage:
#   ./scripts/init-new-pg-version.sh <new_major_version> <full_version> [source_version]
#
# Examples:
#   ./scripts/init-new-pg-version.sh 19 19.0        # copies from PG18
#   ./scripts/init-new-pg-version.sh 19 19.0 18     # explicitly copies from PG18
#   ./scripts/init-new-pg-version.sh 20 20.0 19     # copies from PG19
#
# What this script does:
#   1. Creates directory structure (main/ + distribution dirs)
#   2. Copies and adapts spec file from source version
#   3. Copies and adapts all supporting files (setup, check-db-dir, service, etc.)
#   4. Copies patches from source version
#   5. Creates distribution symlinks (EL-8, EL-9, EL-10, F-42, F-43, SLES-15, SLES-16)
#   6. Creates global Makefile targets (Makefile.global-PGNN, Makefile.global-PGNN-testing)
#   7. Registers the new version in Makefile.global
#

set -euo pipefail

# ─── Configuration ────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "${SCRIPT_DIR}")"
BASE_DIR="${REPO_ROOT}/rpm/redhat/main/non-common"
GLOBAL_DIR="${REPO_ROOT}/rpm/redhat/global"

# Supported distributions for symlinks
DISTROS=("EL-8" "EL-9" "EL-10" "F-42" "F-43" "SLES-15" "SLES-16")

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# ─── Helper Functions ─────────────────────────────────────────────────────────

log_info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[OK]${NC}   $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*"; }

usage() {
    cat <<EOF
Usage: $(basename "$0") <new_major_version> <full_version> [source_version]

Initialize RPM packaging for a new PostgreSQL major version.

Arguments:
  new_major_version   The new major version number (e.g., 19)
  full_version        The full version string (e.g., 19.0)
  source_version      Version to copy from (default: new_major_version - 1)

Examples:
  $(basename "$0") 19 19.0        # Init PG19, copying from PG18
  $(basename "$0") 19 19.0 17     # Init PG19, copying from PG17
  $(basename "$0") 20 20.0        # Init PG20, copying from PG19

The script will:
  1. Create rpm/redhat/main/non-common/postgresql-<VER>/main/ with all files
  2. Create distribution symlinks (EL-8, EL-9, EL-10, F-42, F-43, SLES-15, SLES-16)
  3. Create rpm/redhat/global/Makefile.global-PG<VER> build targets
  4. Register the new version in Makefile.global

After running, you should:
  - Review and update the spec file for new build dependencies or features
  - Test-apply patches against the new source tarball
  - Update patches if context lines have shifted
  - Review the changelog entry
EOF
    exit 1
}

# ─── Argument Parsing ─────────────────────────────────────────────────────────

if [ $# -lt 2 ] || [ $# -gt 3 ]; then
    usage
fi

NEW_VER="$1"
FULL_VER="$2"
SRC_VER="${3:-$((NEW_VER - 1))}"
PREV_VER="$((NEW_VER - 1))"

# Validate inputs
if ! [[ "$NEW_VER" =~ ^[0-9]+$ ]]; then
    log_error "Major version must be a number: $NEW_VER"
    exit 1
fi

if ! [[ "$FULL_VER" =~ ^[0-9]+\.[0-9]+$ ]]; then
    log_error "Full version must be in format X.Y: $FULL_VER"
    exit 1
fi

SRC_DIR="${BASE_DIR}/postgresql-${SRC_VER}/main"
NEW_DIR="${BASE_DIR}/postgresql-${NEW_VER}/main"
NEW_PKG_DIR="${BASE_DIR}/postgresql-${NEW_VER}"

if [ ! -d "$SRC_DIR" ]; then
    log_error "Source directory not found: $SRC_DIR"
    log_error "Available versions:"
    ls -d "${BASE_DIR}/postgresql-"*/main 2>/dev/null | while read -r d; do
        echo "  $(basename "$(dirname "$d")")"
    done
    exit 1
fi

if [ -d "$NEW_DIR" ]; then
    log_error "Target directory already exists: $NEW_DIR"
    log_error "Remove it first if you want to reinitialize:"
    echo "  rm -rf ${NEW_PKG_DIR}"
    exit 1
fi

# ─── Display Plan ─────────────────────────────────────────────────────────────

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "  PostgreSQL ${NEW_VER} RPM Packaging Initialization"
echo "═══════════════════════════════════════════════════════════════════"
echo ""
echo "  New version:      PostgreSQL ${NEW_VER} (${FULL_VER})"
echo "  Source version:   PostgreSQL ${SRC_VER}"
echo "  Previous version: PostgreSQL ${PREV_VER} (for upgrades)"
echo ""
echo "  Source directory:  ${SRC_DIR}"
echo "  Target directory:  ${NEW_DIR}"
echo ""
echo "  Distributions:    ${DISTROS[*]}"
echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo ""

read -rp "Proceed? [y/N] " confirm
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 0
fi

echo ""

# ─── Step 1: Create Directory Structure ───────────────────────────────────────

log_info "Step 1: Creating directory structure..."

mkdir -p "${NEW_DIR}"
log_success "Created ${NEW_DIR}"

# ─── Step 2: Copy and Adapt Spec File ─────────────────────────────────────────

log_info "Step 2: Copying and adapting spec file..."

SRC_SPEC="${SRC_DIR}/postgresql-${SRC_VER}.spec"
NEW_SPEC="${NEW_DIR}/postgresql-${NEW_VER}.spec"

if [ -f "$SRC_SPEC" ]; then
    cp "$SRC_SPEC" "$NEW_SPEC"

    # Update version macros
    sed -i "s/%global pgmajorversion ${SRC_VER}/%global pgmajorversion ${NEW_VER}/g" "$NEW_SPEC"
    sed -i "s/%global pgpackageversion ${SRC_VER}/%global pgpackageversion ${NEW_VER}/g" "$NEW_SPEC"
    sed -i "s/%global prevmajorversion ${PREV_VER}/%global prevmajorversion $((NEW_VER - 1))/g" "$NEW_SPEC"

    # Update version string
    sed -i "s/^Version:        .*/Version:        ${FULL_VER}/" "$NEW_SPEC"
    sed -i "s/^Release:        .*/Release:        1mydbops%{?dist}/" "$NEW_SPEC"

    # Update description references
    sed -i "s/PostgreSQL ${SRC_VER}/PostgreSQL ${NEW_VER}/g" "$NEW_SPEC"
    sed -i "s/postgresql${SRC_VER}/postgresql${NEW_VER}/g" "$NEW_SPEC"
    sed -i "s/postgresql-%{pgmajorversion}/postgresql-%{pgmajorversion}/g" "$NEW_SPEC"

    # Update changelog
    TODAY=$(date +"%a %b %d %Y")
    cat >> "$NEW_SPEC" <<EOF
* ${TODAY} PostgreSQL RPM Packaging <packaging@mydbops.com> - ${FULL_VER}-1mydbops
- Initial package for PostgreSQL ${FULL_VER}
EOF

    log_success "Created spec file: postgresql-${NEW_VER}.spec"
else
    log_error "Source spec file not found: $SRC_SPEC"
    exit 1
fi

# ─── Step 3: Copy and Adapt Supporting Files ──────────────────────────────────

log_info "Step 3: Copying and adapting supporting files..."

# --- setup script ---
SRC_SETUP="${SRC_DIR}/postgresql-${SRC_VER}-setup"
NEW_SETUP="${NEW_DIR}/postgresql-${NEW_VER}-setup"

if [ -f "$SRC_SETUP" ]; then
    cp "$SRC_SETUP" "$NEW_SETUP"
    # Update version references in comments (e.g., "e.g., 18.0" -> "e.g., 19.0")
    sed -i "s/e.g., ${SRC_VER}\./e.g., ${NEW_VER}./g" "$NEW_SETUP"
    # Update PGMAJORVERSION comment (e.g., "e.g., 18 (" -> "e.g., 19 (")
    sed -i "s/e.g., ${SRC_VER} (/e.g., ${NEW_VER} (/g" "$NEW_SETUP"
    # Update pgsql-NN path references
    sed -i "s|pgsql-${SRC_VER}|pgsql-${NEW_VER}|g" "$NEW_SETUP"
    # Update postgresql-NN references
    sed -i "s|postgresql-${SRC_VER}|postgresql-${NEW_VER}|g" "$NEW_SETUP"
    # Update PREVMAJORVERSION comment (e.g., 17 -> prev of new)
    sed -i "s/e.g., $((SRC_VER - 1)), for upgrades/e.g., ${PREV_VER}, for upgrades/g" "$NEW_SETUP"
    # Placeholders remain as xxx/xxxx (spec file replaces them at build time)
    chmod +x "$NEW_SETUP"
    log_success "Created setup script"
else
    log_warn "Source setup script not found, skipping"
fi

# --- check-db-dir ---
SRC_CHECK="${SRC_DIR}/postgresql-${SRC_VER}-check-db-dir"
NEW_CHECK="${NEW_DIR}/postgresql-${NEW_VER}-check-db-dir"

if [ -f "$SRC_CHECK" ]; then
    cp "$SRC_CHECK" "$NEW_CHECK"
    # Update version references in comments
    sed -i "s/e.g., ${SRC_VER}\./e.g., ${NEW_VER}./g" "$NEW_CHECK"
    # Update PGMAJORVERSION comment (e.g., "e.g., 18 (" -> "e.g., 19 (")
    sed -i "s/e.g., ${SRC_VER} (/e.g., ${NEW_VER} (/g" "$NEW_CHECK"
    sed -i "s|pgsql-${SRC_VER}|pgsql-${NEW_VER}|g" "$NEW_CHECK"
    sed -i "s|postgresql-${SRC_VER}|postgresql-${NEW_VER}|g" "$NEW_CHECK"
    sed -i "s/e.g., $((SRC_VER - 1)) for upgrades/e.g., ${PREV_VER} for upgrades/g" "$NEW_CHECK"
    # Update PostgreSQL version in user messages
    sed -i "s/PostgreSQL ${SRC_VER}/PostgreSQL ${NEW_VER}/g" "$NEW_CHECK"
    chmod +x "$NEW_CHECK"
    log_success "Created check-db-dir script"
else
    log_warn "Source check-db-dir not found, skipping"
fi

# --- service file ---
SRC_SERVICE="${SRC_DIR}/postgresql-${SRC_VER}.service"
NEW_SERVICE="${NEW_DIR}/postgresql-${NEW_VER}.service"

if [ -f "$SRC_SERVICE" ]; then
    cp "$SRC_SERVICE" "$NEW_SERVICE"
    sed -i "s|pgsql-${SRC_VER}|pgsql-${NEW_VER}|g" "$NEW_SERVICE"
    sed -i "s|postgresql-${SRC_VER}|postgresql-${NEW_VER}|g" "$NEW_SERVICE"
    sed -i "s|PostgreSQL ${SRC_VER}|PostgreSQL ${NEW_VER}|g" "$NEW_SERVICE"
    sed -i "s|/docs/${SRC_VER}/|/docs/${NEW_VER}/|g" "$NEW_SERVICE"
    sed -i "s|/${SRC_VER}/data|/${NEW_VER}/data|g" "$NEW_SERVICE"
    log_success "Created service file"
else
    log_warn "Source service file not found, skipping"
fi

# --- PAM file (version-independent, just copy) ---
SRC_PAM="${SRC_DIR}/postgresql-${SRC_VER}.pam"
NEW_PAM="${NEW_DIR}/postgresql-${NEW_VER}.pam"

if [ -f "$SRC_PAM" ]; then
    cp "$SRC_PAM" "$NEW_PAM"
    log_success "Created PAM file"
fi

# --- tmpfiles.d ---
SRC_TMP="${SRC_DIR}/postgresql-${SRC_VER}-tmpfiles.d"
NEW_TMP="${NEW_DIR}/postgresql-${NEW_VER}-tmpfiles.d"

if [ -f "$SRC_TMP" ]; then
    cp "$SRC_TMP" "$NEW_TMP"
    log_success "Created tmpfiles.d"
fi

# --- sysusers.conf (version-independent, just copy) ---
SRC_SYSUSERS="${SRC_DIR}/postgresql-${SRC_VER}-sysusers.conf"
NEW_SYSUSERS="${NEW_DIR}/postgresql-${NEW_VER}-sysusers.conf"

if [ -f "$SRC_SYSUSERS" ]; then
    cp "$SRC_SYSUSERS" "$NEW_SYSUSERS"
    log_success "Created sysusers.conf"
fi

# --- libs.conf ---
SRC_LIBS="${SRC_DIR}/postgresql-${SRC_VER}-libs.conf"
NEW_LIBS="${NEW_DIR}/postgresql-${NEW_VER}-libs.conf"

if [ -f "$SRC_LIBS" ]; then
    cp "$SRC_LIBS" "$NEW_LIBS"
    sed -i "s|pgsql-${SRC_VER}|pgsql-${NEW_VER}|g" "$NEW_LIBS"
    log_success "Created libs.conf"
fi

# --- Makefile.regress ---
SRC_REGRESS="${SRC_DIR}/postgresql-${SRC_VER}-Makefile.regress"
NEW_REGRESS="${NEW_DIR}/postgresql-${NEW_VER}-Makefile.regress"

if [ -f "$SRC_REGRESS" ]; then
    cp "$SRC_REGRESS" "$NEW_REGRESS"
    sed -i "s|pgsql-${SRC_VER}|pgsql-${NEW_VER}|g" "$NEW_REGRESS"
    log_success "Created Makefile.regress"
fi

# --- Multilib headers (version-independent, just copy) ---
for header in pg_config.h ecpg_config.h; do
    SRC_HDR="${SRC_DIR}/postgresql-${SRC_VER}-${header}"
    NEW_HDR="${NEW_DIR}/postgresql-${NEW_VER}-${header}"

    if [ -f "$SRC_HDR" ]; then
        cp "$SRC_HDR" "$NEW_HDR"
        log_success "Created ${header}"
    fi
done

# --- README.rpm-dist ---
SRC_README="${SRC_DIR}/postgresql-${SRC_VER}-README.rpm-dist"
NEW_README="${NEW_DIR}/postgresql-${NEW_VER}-README.rpm-dist"

if [ -f "$SRC_README" ]; then
    cp "$SRC_README" "$NEW_README"
    sed -i "s|pgsql-${SRC_VER}|pgsql-${NEW_VER}|g" "$NEW_README"
    sed -i "s|postgresql-${SRC_VER}|postgresql-${NEW_VER}|g" "$NEW_README"
    sed -i "s|postgresql${SRC_VER}|postgresql${NEW_VER}|g" "$NEW_README"
    sed -i "s|/${SRC_VER}/|/${NEW_VER}/|g" "$NEW_README"
    sed -i "s|PostgreSQL ${SRC_VER}|PostgreSQL ${NEW_VER}|g" "$NEW_README"
    log_success "Created README.rpm-dist"
else
    log_warn "Source README.rpm-dist not found, skipping"
fi

# ─── Step 4: Copy Patches ────────────────────────────────────────────────────

log_info "Step 4: Copying patches..."

PATCH_COUNT=0
for patch_file in "${SRC_DIR}"/postgresql-${SRC_VER}-*.patch; do
    if [ -f "$patch_file" ]; then
        patch_name=$(basename "$patch_file")
        new_patch_name="${patch_name/postgresql-${SRC_VER}/postgresql-${NEW_VER}}"
        cp "$patch_file" "${NEW_DIR}/${new_patch_name}"
        PATCH_COUNT=$((PATCH_COUNT + 1))
    fi
done

if [ "$PATCH_COUNT" -gt 0 ]; then
    log_success "Copied ${PATCH_COUNT} patches"
    log_warn "IMPORTANT: Test-apply patches against the new source tarball!"
    log_warn "  cd postgresql-${FULL_VER}/"
    for patch_file in "${NEW_DIR}"/postgresql-${NEW_VER}-*.patch; do
        if [ -f "$patch_file" ]; then
            echo "    patch -p0 --dry-run < $(basename "$patch_file")"
        fi
    done
else
    log_warn "No patches found in source version"
fi

# ─── Step 5: Create Version-Specific Makefile ─────────────────────────────────

log_info "Step 5: Creating version-specific Makefile..."

cat > "${NEW_DIR}/Makefile" <<EOF
#################################
# RPM-specific Makefile         #
# PostgreSQL ${NEW_VER} packaging       #
#################################

# Predefined values
ARCH=\`rpm --eval "%{_arch}"\`
DIR=\`pwd\`
SPECFILE="postgresql-${NEW_VER}.spec"

# Now, include global Makefile
include ../../../../global/Makefile.global
EOF

log_success "Created version Makefile"

# ─── Step 6: Create Distribution Symlinks ─────────────────────────────────────

log_info "Step 6: Creating distribution symlinks..."

for DISTRO in "${DISTROS[@]}"; do
    DISTRO_DIR="${NEW_PKG_DIR}/${DISTRO}"
    mkdir -p "${DISTRO_DIR}"

    # Create symlinks for all files in main/
    for file in "${NEW_DIR}"/*; do
        filename=$(basename "$file")
        if [ -f "$file" ] && [ "$filename" != "Makefile" ]; then
            ln -sf "../main/${filename}" "${DISTRO_DIR}/${filename}"
        fi
    done

    # Copy Makefile (not symlink - may need distro-specific overrides)
    cp "${NEW_DIR}/Makefile" "${DISTRO_DIR}/Makefile"

    log_success "Created symlinks for ${DISTRO}"
done

# ─── Step 7: Create Global Makefile Targets ───────────────────────────────────

log_info "Step 7: Creating global Makefile targets..."

# --- Main build Makefile ---
GLOBAL_MK="${GLOBAL_DIR}/Makefile.global-PG${NEW_VER}"

cat > "${GLOBAL_MK}" <<EOF
#################################
# Makefile for PostgreSQL ${NEW_VER}    #
# packaging                     #
# PostgreSQL RPM Repository     #
#                               #
# Based on mydbops pgrpms          #
#################################
#                               #
#                               #
# build target is for           #
# RPM buildfarm                 #
#                               #
#                               #
#################################


## PostgreSQL ${NEW_VER}

prep${NEW_VER}:
	if [ -f dead.package ]; then echo "This package is marked as dead. Build won't continue"; exit 1; fi
	# Update spec file, patches, etc, before running spectool:
	git pull
	# Use spectool to download source files, especially tarballs.
	spectool -g -S --define "pgmajorversion ${NEW_VER}" --define "pginstdir /usr/pgsql-${NEW_VER}" --define "pgpackageversion ${NEW_VER}" \$(SPECFILE)

build${NEW_VER}: prep${NEW_VER}
	rpmbuild --define "_sourcedir \$(PWD)" \\
	--define "_specdir \$(PWD)" \\
	--define "_buildrootdir \$(HOME)/rpm${NEW_VER}/BUILDROOT" \\
	--define "_builddir \$(HOME)/rpm${NEW_VER}/BUILD" \\
	--define "_srcrpmdir \$(HOME)/rpm${NEW_VER}/SRPMS" \\
	--define "_rpmdir \$(HOME)/rpm${NEW_VER}/RPMS/" \\
	--define "pgmajorversion ${NEW_VER}" --define "pginstdir /usr/pgsql-${NEW_VER}" --define "pgpackageversion ${NEW_VER}" \\
	-bb \$(SPECFILE)
	make bfsrpm${NEW_VER}

srpm${NEW_VER}: prep${NEW_VER}
	rpmbuild --define "_sourcedir ." --define "_specdir ." \\
	--define "_builddir ." --define "_srcrpmdir ." \\
	--define "_buildrootdir \$(HOME)/rpm${NEW_VER}/BUILDROOT" \\
	--define "pgmajorversion ${NEW_VER}" --define "pginstdir /usr/pgsql-${NEW_VER}" --define "pgpackageversion ${NEW_VER}" \\
	--define "_rpmdir ." --nodeps -bs \$(SPECFILE)

bfsrpm${NEW_VER}: prep${NEW_VER}
	rpmbuild --define "_sourcedir ." --define "_specdir ." \\
	--define "_builddir ." --define "_srcrpmdir \$(HOME)/rpm${NEW_VER}/SRPMS" \\
	--define "_buildrootdir \$(HOME)/rpm${NEW_VER}/BUILDROOT" \\
	--define "pgmajorversion ${NEW_VER}" --define "pginstdir /usr/pgsql-${NEW_VER}" --define "pgpackageversion ${NEW_VER}" \\
	--define "_rpmdir ." --nodeps -bs \$(SPECFILE)

bfnoprepsrpm${NEW_VER}:
	rpmbuild --define "_sourcedir ." --define "_specdir ." \\
	--define "_builddir ." --define "_srcrpmdir \$(HOME)/rpm${NEW_VER}/SRPMS" \\
	--define "_buildrootdir \$(HOME)/rpm${NEW_VER}/BUILDROOT" \\
	--define "pgmajorversion ${NEW_VER}" --define "pginstdir /usr/pgsql-${NEW_VER}" --define "pgpackageversion ${NEW_VER}" \\
	--define "_rpmdir ." --nodeps -bs \$(SPECFILE)

bfnosignsrpm${NEW_VER}: prep${NEW_VER}
	rpmbuild --define "_sourcedir ." --define "_specdir ." \\
	--define "_buildrootdir \$(HOME)/rpm${NEW_VER}/BUILDROOT" \\
	--define "_builddir ." --define "_srcrpmdir \$(HOME)/rpm${NEW_VER}/SRPMS" \\
	--define "pgmajorversion ${NEW_VER}" --define "pginstdir /usr/pgsql-${NEW_VER}" --define "pgpackageversion ${NEW_VER}" \\
	--define "_rpmdir ." --nodeps -bs \$(SPECFILE)

rpm${NEW_VER}: prep${NEW_VER}
	rpmbuild --define "_sourcedir \$(PWD)" \\
	--define "_specdir \$(PWD)" \\
	--define "_builddir \$(PWD)" \\
	--define "_buildrootdir \$(HOME)/rpm${NEW_VER}/BUILDROOT" \\
	--define "_srcrpmdir \$(PWD)" \\
	--define "_rpmdir \$(PWD)" \\
	--define "pgmajorversion ${NEW_VER}" --define "pginstdir /usr/pgsql-${NEW_VER}" --define "pgpackageversion ${NEW_VER}" \\
	-bb \$(SPECFILE)

nosignbuild${NEW_VER}: prep${NEW_VER}
	rpmbuild --define "_sourcedir \$(PWD)" \\
	--define "_specdir \$(PWD)" \\
	--define "_builddir \$(HOME)/rpm${NEW_VER}/BUILD" \\
	--define "_buildrootdir \$(HOME)/rpm${NEW_VER}/BUILDROOT" \\
	--define "_srcrpmdir \$(HOME)/rpm${NEW_VER}/SRPMS" \\
	--define "_rpmdir \$(HOME)/rpm${NEW_VER}/RPMS/" \\
	--define "pgmajorversion ${NEW_VER}" --define "pginstdir /usr/pgsql-${NEW_VER}" --define "pgpackageversion ${NEW_VER}" \\
	-bb \$(SPECFILE)
	make bfnosignsrpm${NEW_VER}

noprepbuild${NEW_VER}:
	rpmbuild --define "_sourcedir ." --define "_specdir ." \\
	--define "_builddir ." --define "_srcrpmdir \$(HOME)/rpm${NEW_VER}/SRPMS" \\
	--define "_buildrootdir \$(HOME)/rpm${NEW_VER}/BUILDROOT" \\
	--define "pgmajorversion ${NEW_VER}" --define "pginstdir /usr/pgsql-${NEW_VER}" --define "pgpackageversion ${NEW_VER}" \\
	--define "_rpmdir ." --nodeps -bs \$(SPECFILE)

	rpmbuild --define "_sourcedir \$(PWD)" \\
	--define "_specdir \$(PWD)" \\
	--define "_builddir \$(HOME)/rpm${NEW_VER}/BUILD" \\
	--define "_buildrootdir \$(HOME)/rpm${NEW_VER}/BUILDROOT" \\
	--define "_srcrpmdir \$(HOME)/rpm${NEW_VER}/SRPMS" \\
	--define "_rpmdir \$(HOME)/rpm${NEW_VER}/RPMS/" \\
	--define "pgmajorversion ${NEW_VER}" --define "pginstdir /usr/pgsql-${NEW_VER}" --define "pgpackageversion ${NEW_VER}" \\
	-bb \$(SPECFILE)

nopreprpm${NEW_VER}:
	rpmbuild --define "_sourcedir \$(PWD)" \\
	--define "_specdir \$(PWD)" \\
	--define "_builddir \$(PWD)" \\
	--define "_buildrootdir \$(HOME)/rpm${NEW_VER}/BUILDROOT" \\
	--define "_srcrpmdir \$(PWD)" \\
	--define "_rpmdir \$(PWD)" \\
	--define "pgmajorversion ${NEW_VER}" --define "pginstdir /usr/pgsql-${NEW_VER}" --define "pgpackageversion ${NEW_VER}" \\
	-bb \$(SPECFILE)

noprepsrpm${NEW_VER}:
	rpmbuild --define "_sourcedir ." --define "_specdir ." \\
	--define "_builddir ." --define "_srcrpmdir ." \\
	--define "_buildrootdir \$(HOME)/rpm${NEW_VER}/BUILDROOT" \\
	--define "pgmajorversion ${NEW_VER}" --define "pginstdir /usr/pgsql-${NEW_VER}" --define "pgpackageversion ${NEW_VER}" \\
	--define "_rpmdir ." --nodeps -bs \$(SPECFILE)
EOF

log_success "Created ${GLOBAL_MK}"

# --- Testing build Makefile ---
GLOBAL_MK_TEST="${GLOBAL_DIR}/Makefile.global-PG${NEW_VER}-testing"

cat > "${GLOBAL_MK_TEST}" <<EOF
#################################
# Makefile for PostgreSQL ${NEW_VER}    #
# packaging (testing)           #
# PostgreSQL RPM Repository     #
#################################

## PostgreSQL ${NEW_VER} testing build targets

prep${NEW_VER}testing:
	if [ -f dead.package ]; then echo "This package is marked as dead. Build won't continue"; exit 1; fi
	git pull
	spectool -g -S --define "pgmajorversion ${NEW_VER}" --define "pginstdir /usr/pgsql-${NEW_VER}" --define "pgpackageversion ${NEW_VER}" \$(SPECFILE)

build${NEW_VER}testing: prep${NEW_VER}testing
	rpmbuild --define "_sourcedir \$(PWD)" \\
	--define "_specdir \$(PWD)" \\
	--define "_buildrootdir \$(HOME)/rpm${NEW_VER}-testing/BUILDROOT" \\
	--define "_builddir \$(HOME)/rpm${NEW_VER}-testing/BUILD" \\
	--define "_srcrpmdir \$(HOME)/rpm${NEW_VER}-testing/SRPMS" \\
	--define "_rpmdir \$(HOME)/rpm${NEW_VER}-testing/RPMS/" \\
	--define "pgmajorversion ${NEW_VER}" --define "pginstdir /usr/pgsql-${NEW_VER}" --define "pgpackageversion ${NEW_VER}" \\
	-bb \$(SPECFILE)

srpm${NEW_VER}testing: prep${NEW_VER}testing
	rpmbuild --define "_sourcedir ." --define "_specdir ." \\
	--define "_builddir ." --define "_srcrpmdir ." \\
	--define "_buildrootdir \$(HOME)/rpm${NEW_VER}-testing/BUILDROOT" \\
	--define "pgmajorversion ${NEW_VER}" --define "pginstdir /usr/pgsql-${NEW_VER}" --define "pgpackageversion ${NEW_VER}" \\
	--define "_rpmdir ." --nodeps -bs \$(SPECFILE)

rpm${NEW_VER}testing: prep${NEW_VER}testing
	rpmbuild --define "_sourcedir \$(PWD)" \\
	--define "_specdir \$(PWD)" \\
	--define "_builddir \$(PWD)" \\
	--define "_buildrootdir \$(HOME)/rpm${NEW_VER}-testing/BUILDROOT" \\
	--define "_srcrpmdir \$(PWD)" \\
	--define "_rpmdir \$(PWD)" \\
	--define "pgmajorversion ${NEW_VER}" --define "pginstdir /usr/pgsql-${NEW_VER}" --define "pgpackageversion ${NEW_VER}" \\
	-bb \$(SPECFILE)
EOF

log_success "Created ${GLOBAL_MK_TEST}"

# ─── Step 8: Register in Global Makefile ──────────────────────────────────────

log_info "Step 8: Registering in global Makefile..."

GLOBAL_MAKEFILE="${GLOBAL_DIR}/Makefile.global"

# Check if already registered
if grep -q "Makefile.global-PG${NEW_VER}" "$GLOBAL_MAKEFILE"; then
    log_warn "PG${NEW_VER} already registered in Makefile.global"
else
    # Add include lines before the end of file
    echo "include ../../../../global/Makefile.global-PG${NEW_VER}" >> "$GLOBAL_MAKEFILE"
    echo "include ../../../../global/Makefile.global-PG${NEW_VER}-testing" >> "$GLOBAL_MAKEFILE"
    log_success "Registered PG${NEW_VER} in Makefile.global"
fi

# ─── Step 9: Summary ─────────────────────────────────────────────────────────

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "  Initialization Complete!"
echo "═══════════════════════════════════════════════════════════════════"
echo ""
echo "  Files created:"
echo ""

# Count files
TOTAL_FILES=0
echo "  ${NEW_DIR}/"
for f in "${NEW_DIR}"/*; do
    if [ -f "$f" ]; then
        echo "    $(basename "$f")"
        TOTAL_FILES=$((TOTAL_FILES + 1))
    fi
done

echo ""
echo "  Distribution symlinks:"
for DISTRO in "${DISTROS[@]}"; do
    LINK_COUNT=$(find "${NEW_PKG_DIR}/${DISTRO}" -type l 2>/dev/null | wc -l)
    echo "    ${DISTRO}/  (${LINK_COUNT} symlinks + Makefile)"
done

echo ""
echo "  Global Makefiles:"
echo "    ${GLOBAL_MK}"
echo "    ${GLOBAL_MK_TEST}"

echo ""
echo "  Total: ${TOTAL_FILES} files in main/, ${#DISTROS[@]} distribution directories"
echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo ""
echo "  Next steps:"
echo ""
echo "  1. Download the source tarball:"
echo "     wget https://ftp.postgresql.org/pub/source/v${FULL_VER}/postgresql-${FULL_VER}.tar.bz2"
echo ""
echo "  2. Test-apply patches against the new source:"
echo "     tar xjf postgresql-${FULL_VER}.tar.bz2"
echo "     cd postgresql-${FULL_VER}"
for patch_file in "${NEW_DIR}"/postgresql-${NEW_VER}-*.patch; do
    if [ -f "$patch_file" ]; then
        echo "     patch -p0 --dry-run < ../$(basename "$patch_file")"
    fi
done
echo ""
echo "  3. Review the spec file for new dependencies or feature flags:"
echo "     vim ${NEW_SPEC}"
echo ""
echo "  4. Review upstream release notes for packaging-relevant changes:"
echo "     https://www.postgresql.org/docs/${NEW_VER}/release-${NEW_VER//./-}.html"
echo ""
echo "  5. Build a test SRPM:"
echo "     cd ${NEW_DIR} && make srpm${NEW_VER}"
echo ""
echo "═══════════════════════════════════════════════════════════════════"
