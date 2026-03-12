#!/usr/bin/bash

#########################################################
#                                                       #
# PostgreSQL RPM Packaging - Package Build Script       #
# Based on PGDG pgrpms                                  #
#                                                       #
#########################################################

# Include common values:
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/global.sh"

# Throw an error if less than two arguments are supplied:
if [ $# -le 1 ]; then
    echo
    echo "${red}ERROR:${reset} This script must be run with at least two parameters:"
    echo "       package name, package version"
    echo "       and optional: The actual package name to sign, and also the PostgreSQL version to build against"
    echo
    echo "Usage: $0 <package_name> <sign_package_name> [pg_version]"
    echo
    echo "Examples:"
    echo "  $0 pg_stat_monitor pg_stat_monitor           # Build for all PG versions"
    echo "  $0 pg_stat_monitor pg_stat_monitor 17        # Build for PG 17 only"
    echo "  $0 barman barman                             # Build common package"
    echo
    exit 1
fi

# The name of the package in the git tree (pgpool-II-41, postgresql-16, etc)
packagename=$1
# Actual package name to sign (postgresql16, pgpool-II, postgis34, etc).
signPackageName=$2
# Optional: The PostgreSQL major version the package will be built against.
# Leave empty to build against all supported PostgreSQL versions.
buildVersion=$3

#################################
#       Build packages          #
#################################

# Stable packages can be in 3 places: Either in "common", "non-common" or "extras" directories.
# This script currently ignores "non-free" repo.

#################
# Common repo   #
#################

# If the package is in common, then build it, sign it and exit safely:
if [ -d "${GITREPOPATH}/rpm/redhat/main/common/${packagename}/${git_os}" ]; then
    echo "${green}Ok, this is a common package, and I am building ${packagename} for ${git_os} for common repo.${reset}"
    sleep 1
    cd "${GITREPOPATH}/rpm/redhat/main/common/${packagename}/${git_os}"
    time make commonbuild
    # Get the package version after building the package so that we get the latest version:
    packageVersion=$(get_package_version "*.spec")
    cd
    sign_package rpmcommon
    exit 0
fi

#########################
#   Non-Common repo     #
#########################

# If the package is in "non-common", then search the package for all of the values in the
# "pgStableBuilds" parameter (a.k.a. supported versions), and build them. After all of the
# packages are built, sign them.

if [ -d "${GITREPOPATH}/rpm/redhat/main/non-common/${packagename}/${git_os}" ]; then
    # Build package against all PostgreSQL versions if 3rd parameter is not given:
    if [ -z "${buildVersion}" ]; then
        :
    else
        if [[ "${pgStableBuilds[@]}" =~ "${buildVersion}" ]]; then
            declare -a pgStableBuilds=("${buildVersion}")
        else
            echo "${red}ERROR:${reset} PostgreSQL version ${buildVersion} is not supported."
            exit 1
        fi
    fi

    for packageBuildVersion in ${pgStableBuilds[@]}; do
        if [ -d "${GITREPOPATH}/rpm/redhat/main/non-common/${packagename}/${git_os}" ]; then
            echo "${green}Ok, building ${packagename} on ${git_os} against PostgreSQL ${packageBuildVersion}${reset}"
            sleep 1
            cd "${GITREPOPATH}/rpm/redhat/main/non-common/${packagename}/${git_os}"
            echo "time make build${packageBuildVersion}"
            time make build${packageBuildVersion}
            # Get the package version after building the package so that we get the latest version:
            packageVersion=$(get_package_version "*.spec")
            cd
            sign_package rpm${packageBuildVersion}
        fi
    done
    exit 0
fi # End of non-common build

#################################
#        Extras repo            #
#################################

# Build the package in the directly if it is in the "extras" repo.
if [ $extrasrepoenabled = 1 ]; then
    # First make sure that extras repo is available for this platform:
    if [ -d "${GITREPOPATH}/rpm/redhat/main/extras/${packagename}/${git_os}" ]; then
        echo "${green}Ok, building ${packagename} on ${git_os} for extras repo${reset}"
        sleep 1
        cd "${GITREPOPATH}/rpm/redhat/main/extras/${packagename}/${git_os}"
        time make extrasbuild
        packageVersion=$(get_package_version "*.spec")
        cd
        sign_package pgdg
        exit 0
    fi
else
    echo "${blue}INFO:${reset} Extras repo is not enabled on this platform"
fi

#################################
#   Package is not available!   #
#################################

echo "${red}ERROR:${reset} Package '${packagename}' does not exist in any of the repos (common, non-common, extras)"
echo "Available repos checked:"
echo "  - ${GITREPOPATH}/rpm/redhat/main/common/${packagename}/${git_os}"
echo "  - ${GITREPOPATH}/rpm/redhat/main/non-common/${packagename}/${git_os}"
echo "  - ${GITREPOPATH}/rpm/redhat/main/extras/${packagename}/${git_os}"
exit 1
