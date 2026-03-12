#!/usr/bin/bash

#########################################################
#                                                       #
# PostgreSQL RPM Packaging - Build Configuration        #
# Based on PGDG pgrpms                                  #
#                                                       #
#########################################################

# Color schemes
red=`tput setaf 1`
green=`tput setaf 2`
blue=`tput setaf 4`
reset=`tput sgr0`

# Build environment configuration
# Modify these values according to your build environment

export os=rhel-9                # rhel-8, rhel-9, rhel-10, sles-15, fedora-42, fedora-43
export osminversion=0           # Minor version (e.g., 9.4 -> 4)
export osislatest=1             # Is this the latest minor version? 1 or 0
export osarch=x86_64            # x86_64, aarch64, ppc64le
export osdistro=redhat          # fedora, redhat, suse
export git_os=EL-9              # EL-8, EL-9, EL-10, F-42, F-43, SLES-15, SLES-16
export extrasrepoenabled=1      # 1 or 0. Currently for RHEL and SLES.

# GPG signing configuration
export GPG_TTY=$(tty)
export GPG_PASSWORD=""          # Set your GPG password or use gpg-agent

# AWS S3 configuration (for package distribution)
export AWS_PAGER=""
export awssrpmurl=""            # S3 URL for SRPMs
export awsdebuginfourl=""       # S3 URL for debug info

# CloudFront distribution IDs (for CDN invalidation)
export CF_DEBUG_DISTRO_ID=""
export CF_SRPM_DISTRO_ID=""

# Supported PostgreSQL versions
declare -a pgStableBuilds=("18 17 16 15 14")
declare -a pgTestBuilds=("18 17 16 15 14")
declare -a pgBetaVersion=18
declare -a pgAlphaVersion=19

# Git repository path
export GITREPOPATH="${HOME}/git/packaging-postgresql"

# Common function to sign packages
sign_package(){
    # Remove all files with .sig suffix. They are leftovers which appear
    # when signing process is not completed. Signing will be broken when
    # they exist.
    find ~/rpm* pgdg* -iname "*.sig" -print0 2>/dev/null | xargs -0 /bin/rm -v -rf "{}"

    # Remove all buildreqs.nosrc packages:
    find ~/rpm* pgdg* -iname "*buildreqs.nosrc*" -print0 2>/dev/null | xargs -0 /bin/rm -v -rf "{}"

    # Find the packages, and sign them
    # The first parameter refers to the location of the RPMs:
    if [ -n "${GPG_PASSWORD}" ] && [ -f ~/bin/signrpms.expect ]; then
        for signpackagelist in `find ~/$1* -iname "*$signPackageName*$packageVersion*.rpm" 2>/dev/null`; do
            /usr/bin/expect ~/bin/signrpms.expect $signpackagelist
        done
    else
        echo "${blue}INFO:${reset} Skipping package signing (GPG not configured)"
    fi
}

# Function to check if a package exists in a repository
package_exists() {
    local repo_type=$1
    local package_name=$2

    case $repo_type in
        common)
            [ -d "${GITREPOPATH}/rpm/redhat/main/common/${package_name}" ]
            ;;
        non-common)
            [ -d "${GITREPOPATH}/rpm/redhat/main/non-common/${package_name}" ]
            ;;
        extras)
            [ -d "${GITREPOPATH}/rpm/redhat/main/extras/${package_name}" ]
            ;;
        non-free)
            [ -d "${GITREPOPATH}/rpm/redhat/main/non-free/${package_name}" ]
            ;;
        *)
            return 1
            ;;
    esac
}

# Function to get package version from spec file
get_package_version() {
    local specfile=$1
    rpmspec --define "pgmajorversion ${pgAlphaVersion}" -q --qf "%{Version}\n" "${specfile}" 2>/dev/null | head -n 1
}

echo "${green}Build environment loaded successfully.${reset}"
echo "OS: ${os} (${osarch})"
echo "Git OS identifier: ${git_os}"
echo "PostgreSQL stable versions: ${pgStableBuilds[@]}"
