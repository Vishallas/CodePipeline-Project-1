#!/usr/bin/bash

#########################################################
#                                                       #
# PostgreSQL RPM Packaging - Setup Build Directories    #
# Creates required directory structure for building     #
# Based on PGDG pgrpms                                  #
#                                                       #
#########################################################

# Include common values:
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/global.sh"

echo "${blue}Setting up build directories...${reset}"

# Create PostgreSQL version-specific build directories
for ver in ${pgStableBuilds[@]}; do
    echo "Creating build directories for PostgreSQL ${ver}..."
    mkdir -p "${HOME}/rpm${ver}"/{BUILD,BUILDROOT,RPMS,SRPMS,SOURCES,SPECS}
    mkdir -p "${HOME}/rpm${ver}/RPMS"/{x86_64,aarch64,ppc64le,noarch}
done

# Create testing directories
for ver in ${pgTestBuilds[@]}; do
    echo "Creating testing build directories for PostgreSQL ${ver}..."
    mkdir -p "${HOME}/rpm${ver}-testing"/{BUILD,BUILDROOT,RPMS,SRPMS,SOURCES,SPECS}
    mkdir -p "${HOME}/rpm${ver}-testing/RPMS"/{x86_64,aarch64,ppc64le,noarch}
done

# Create common build directory
echo "Creating common build directories..."
mkdir -p "${HOME}/rpmcommon"/{BUILD,BUILDROOT,RPMS,SRPMS,SOURCES,SPECS}
mkdir -p "${HOME}/rpmcommon/RPMS"/{x86_64,aarch64,ppc64le,noarch}

# Create common-testing directory
mkdir -p "${HOME}/rpmcommon-testing"/{BUILD,BUILDROOT,RPMS,SRPMS,SOURCES,SPECS}
mkdir -p "${HOME}/rpmcommon-testing/RPMS"/{x86_64,aarch64,ppc64le,noarch}

# Create extras build directory
echo "Creating extras build directories..."
mkdir -p "${HOME}/pgdg.extras"/{BUILD,BUILDROOT,RPMS,SRPMS,SOURCES,SPECS}
mkdir -p "${HOME}/pgdg.extras/RPMS"/{x86_64,aarch64,ppc64le,noarch}

# Create extras-testing directory
mkdir -p "${HOME}/pgdg.extras-testing"/{BUILD,BUILDROOT,RPMS,SRPMS,SOURCES,SPECS}
mkdir -p "${HOME}/pgdg.extras-testing/RPMS"/{x86_64,aarch64,ppc64le,noarch}

# Create bin directory for scripts
mkdir -p "${HOME}/bin"

# Copy scripts to bin directory
echo "Copying build scripts to ~/bin..."
cp "${SCRIPT_DIR}"/*.sh "${HOME}/bin/" 2>/dev/null || true
chmod +x "${HOME}/bin"/*.sh 2>/dev/null || true

echo "${green}Build directories created successfully!${reset}"
echo
echo "Directory structure:"
echo "  ~/rpm{14,15,16,17,18}/      - PostgreSQL version-specific builds"
echo "  ~/rpmcommon/                - Common (version-independent) builds"
echo "  ~/pgdg.extras/              - Extras repository builds"
echo "  ~/bin/                      - Build scripts"
echo
echo "To start building packages, use:"
echo "  ~/bin/packagebuild.sh <package_name> <sign_name> [pg_version]"
