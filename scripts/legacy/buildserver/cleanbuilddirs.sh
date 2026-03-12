#!/usr/bin/bash

#########################################################
#                                                       #
# PostgreSQL RPM Packaging - Clean Build Directories    #
# Based on PGDG pgrpms                                  #
#                                                       #
#########################################################

# Include common values:
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/global.sh"

echo "${blue}Cleaning build directories...${reset}"

# Clean PostgreSQL version-specific build directories
for ver in ${pgStableBuilds[@]}; do
    if [ -d "${HOME}/rpm${ver}" ]; then
        echo "Cleaning ${HOME}/rpm${ver}..."
        rm -rf "${HOME}/rpm${ver}/BUILD/"*
        rm -rf "${HOME}/rpm${ver}/BUILDROOT/"*
        # Keep RPMS and SRPMS directories but clean old packages if requested
    fi
done

# Clean common build directory
if [ -d "${HOME}/rpmcommon" ]; then
    echo "Cleaning ${HOME}/rpmcommon..."
    rm -rf "${HOME}/rpmcommon/BUILD/"*
    rm -rf "${HOME}/rpmcommon/BUILDROOT/"*
fi

# Clean extras build directory
if [ -d "${HOME}/pgdg.extras" ]; then
    echo "Cleaning ${HOME}/pgdg.extras..."
    rm -rf "${HOME}/pgdg.extras/BUILD/"*
    rm -rf "${HOME}/pgdg.extras/BUILDROOT/"*
fi

# Clean testing directories
for ver in ${pgTestBuilds[@]}; do
    if [ -d "${HOME}/rpm${ver}-testing" ]; then
        echo "Cleaning ${HOME}/rpm${ver}-testing..."
        rm -rf "${HOME}/rpm${ver}-testing/BUILD/"*
        rm -rf "${HOME}/rpm${ver}-testing/BUILDROOT/"*
    fi
done

echo "${green}Build directories cleaned.${reset}"
