#!/usr/bin/bash

#########################################################
#                                                       #
# PostgreSQL RPM Packaging - Package Sync Script        #
# Syncs built packages to repository                    #
# Based on PGDG pgrpms                                  #
#                                                       #
#########################################################

# Include common values:
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/global.sh"

# Check arguments
if [ $# -lt 1 ]; then
    echo
    echo "${red}ERROR:${reset} This script must be run with at least one parameter:"
    echo "       repository type (common, non-common, extras)"
    echo
    echo "Usage: $0 <repo_type> [pg_version]"
    echo
    echo "Examples:"
    echo "  $0 non-common 17     # Sync PostgreSQL 17 packages"
    echo "  $0 common            # Sync common packages"
    echo "  $0 extras            # Sync extras packages"
    echo
    exit 1
fi

repo_type=$1
pg_version=$2

# Function to sync packages to a destination
sync_packages() {
    local source_dir=$1
    local dest_dir=$2
    local description=$3

    if [ ! -d "${source_dir}" ]; then
        echo "${red}ERROR:${reset} Source directory does not exist: ${source_dir}"
        return 1
    fi

    echo "${green}Syncing ${description}...${reset}"
    echo "Source: ${source_dir}"
    echo "Destination: ${dest_dir}"

    # Create destination directory if it doesn't exist
    mkdir -p "${dest_dir}"

    # Use rsync for efficient copying
    rsync -avz --progress "${source_dir}/" "${dest_dir}/"

    if [ $? -eq 0 ]; then
        echo "${green}Successfully synced ${description}${reset}"
    else
        echo "${red}Failed to sync ${description}${reset}"
        return 1
    fi
}

# Function to update repository metadata
update_repo_metadata() {
    local repo_dir=$1

    echo "${blue}Updating repository metadata for ${repo_dir}...${reset}"

    if command -v createrepo_c &> /dev/null; then
        createrepo_c --update "${repo_dir}"
    elif command -v createrepo &> /dev/null; then
        createrepo --update "${repo_dir}"
    else
        echo "${red}WARNING:${reset} createrepo not found, skipping metadata update"
        return 1
    fi
}

case $repo_type in
    common)
        source_dir="${HOME}/rpmcommon/RPMS"
        dest_dir="${HOME}/repo/common/${osarch}"
        sync_packages "${source_dir}" "${dest_dir}" "common packages"
        update_repo_metadata "${dest_dir}"
        ;;

    non-common)
        if [ -z "${pg_version}" ]; then
            # Sync all PostgreSQL versions
            for ver in ${pgStableBuilds[@]}; do
                source_dir="${HOME}/rpm${ver}/RPMS"
                dest_dir="${HOME}/repo/${ver}/${os}/${osarch}"
                sync_packages "${source_dir}" "${dest_dir}" "PostgreSQL ${ver} packages"
                update_repo_metadata "${dest_dir}"
            done
        else
            # Sync specific version
            source_dir="${HOME}/rpm${pg_version}/RPMS"
            dest_dir="${HOME}/repo/${pg_version}/${os}/${osarch}"
            sync_packages "${source_dir}" "${dest_dir}" "PostgreSQL ${pg_version} packages"
            update_repo_metadata "${dest_dir}"
        fi
        ;;

    extras)
        source_dir="${HOME}/pgdg.extras/RPMS"
        dest_dir="${HOME}/repo/extras/${os}/${osarch}"
        sync_packages "${source_dir}" "${dest_dir}" "extras packages"
        update_repo_metadata "${dest_dir}"
        ;;

    *)
        echo "${red}ERROR:${reset} Unknown repository type: ${repo_type}"
        echo "Valid types: common, non-common, extras"
        exit 1
        ;;
esac

echo "${green}Package sync completed.${reset}"
