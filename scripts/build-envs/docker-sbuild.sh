#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# docker-sbuild.sh — Docker + sbuild + mmdebstrap build environment driver
# ─────────────────────────────────────────────────────────────────────────────
#
# Builds DEB packages inside Docker using sbuild + mmdebstrap for:
#   ✓ Isolated chroots (mmdebstrap)
#   ✓ Reproducible builds (sbuild)
#   ✓ Automatic dependency resolution
#   ✓ Fast chroot creation (5-15 min vs 20-40 min)
#
# Architecture:
#   Docker Container (minimal ~500MB):
#   ├── mmdebstrap: Fast chroot creation
#   ├── sbuild: Build management
#   └── Build tools
#
#   Build Chroots (created dynamically):
#   ├── Base system (minimal)
#   ├── Build dependencies (installed per-build)
#   └── Build happens here (isolated)
#
# Usage:
#   ./scripts/build-env.sh build-all-deb --builder docker-sbuild --pg-major 16 --distro bookworm
#
# ─────────────────────────────────────────────────────────────────────────────

DRIVER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${DRIVER_DIR}/common.sh"

# ─── Configuration ─────────────────────────────────────────────────────────

DOCKER_CMD="${DOCKER_CMD:-docker}"
DOCKER_IMAGE_PREFIX="${DOCKER_IMAGE_PREFIX:-postgresql-build}"

# ─── Dependency Check ──────────────────────────────────────────────────────

builder_docker_sbuild_check_deps() {
    if ! command -v "$DOCKER_CMD" &>/dev/null; then
        if command -v podman &>/dev/null; then
            DOCKER_CMD="podman"
            log_info "Using podman as Docker alternative"
        else
            log_error "Neither docker nor podman found"
            return 1
        fi
    fi
    log_success "Docker sbuild environment ready (${DOCKER_CMD})"
    return 0
}

# ─── Helpers ───────────────────────────────────────────────────────────────

_docker_image_tag() {
    local distro="$1"
    case "$distro" in
        bookworm)  echo "debian-bookworm" ;;
        bullseye)  echo "debian-bullseye" ;;
        trixie)    echo "debian-trixie" ;;
        jammy)     echo "ubuntu-jammy" ;;
        focal)     echo "ubuntu-focal" ;;
        noble)     echo "ubuntu-noble" ;;
        *)  echo "$distro" ;;
    esac
}

_docker_ensure_image() {
    local distro="$1"
    local tag="sbuild"
    local full_image="${DOCKER_IMAGE_PREFIX}:${tag}"

    if ! ${DOCKER_CMD} image inspect "$full_image" &>/dev/null; then
        local dockerfile_dir="${BUILDENV_PROJECT_ROOT}/docker/${tag}"
        if [[ -f "${dockerfile_dir}/Dockerfile" ]]; then
            log_info "Building Docker image: ${full_image}"
            if ! ${DOCKER_CMD} build -t "$full_image" "${dockerfile_dir}"; then
                log_error "Failed to build Docker image"
                return 1
            fi
        else
            log_error "Dockerfile not found: ${dockerfile_dir}/Dockerfile"
            return 1
        fi
    fi
    echo "$full_image"
}

# ──────────────────────────────────────────────────────────────────────────────
# Build PostgreSQL DEB via Docker + sbuild + mmdebstrap (PERSISTENT chroot tarball)
#
# - Reuses cached chroot stored on a Docker volume mounted at /var/cache/sbuild
# - Chroot key: <DIST>-<ARCH>-sbuild.tar.gz
# - Overlays packaging "debian/" from your repo onto upstream PostgreSQL sources
# - Uses a mounted config file for proper multi-line environment variable handling
#
# Args:
#   1) package      : e.g. postgresql-15 (informational / output naming)
#   2) distro       : bookworm / jammy / noble ...
#   3) arch         : amd64 / arm64 / armhf ...
#   4) pg_major     : 15 / 16 ...
#   5) pg_full      : 15.5 / 16.1 ...
#   6) pg_release   : 1 (debian revision; informational unless you also update changelog outside)
#   7) output_base  : optional, default: ${BUILDENV_PROJECT_ROOT}/output
#
# Optional env:
#   UPSTREAM_URL            : tarball URL override
#   EXTRA_REPOS             : extra "deb ..." lines (space/newline separated)
#   FORCE_CHROOT_REBUILD    : 1 to delete and recreate cached tarball
#   BUILDER_CHROOT_VOLUME   : docker volume name (default: pg-builder-chroot)
# ──────────────────────────────────────────────────────────────────────────────
builder_docker_sbuild_build_deb() {
    local package="$1"
    local distro="$2"
    local pg_major="$3"
    local pg_full="$4"
    local pg_release="$5"
    local output_base="${6:-${BUILDENV_PROJECT_ROOT}/output}"
    local arch="amd64"  # Currently only supporting amd64 builds

    local full_image
    full_image=$(_docker_ensure_image "$distro") || return 1

    local build_dir
    build_dir=$(init_build_output "docker-sbuild" "$distro" "$package" "$output_base")
    chmod -R a+rwX "${build_dir}"

    local log_file
    log_file=$(get_build_log "docker-sbuild" "$distro" "$package" "$output_base")

    local make_jobs
    make_jobs=$(nproc 2>/dev/null || echo 4)

    # Locate package source directory
    local pkg_dir=""
    if [[ -d "${BUILDENV_PROJECT_ROOT}/debian/main/non-common/${package}/${distro}" ]]; then
        pkg_dir="debian/main/non-common/${package}/${distro}"
    elif [[ -d "${BUILDENV_PROJECT_ROOT}/debian/main/non-common/${package}/main" ]]; then
        pkg_dir="debian/main/non-common/${package}/main"
    else
        log_error "Package directory not found for: ${package}"
        return 1
    fi

    local container_workdir="/build/${pkg_dir}"
    local chroot_vol="${BUILDER_CHROOT_VOLUME:-pg-builder-chroot}"

    # Create a temporary config file to be mounted into the container
    # This ensures multi-line environment variables (like EXTRA_REPOS) are preserved
    local config_file
    config_file=$(mktemp /tmp/docker-sbuild-config-XXXXXX.sh)
    trap "rm -f '${config_file}'" RETURN

    cat > "${config_file}" <<'CONFIG_EOF'
# ─────────────────────────────────────────────────────────────────────────────
# docker-sbuild build configuration (auto-generated)
# ─────────────────────────────────────────────────────────────────────────────

CONFIG_EOF

    # Write simple exports for scalar values
    cat >> "${config_file}" <<CONFIG_VARS
export DIST="${distro}"
export ARCH="${arch}"
export PG_VERSION="${pg_full}"
export PG_MAJOR="${pg_major}"
export MAKE_JOBS="${make_jobs}"
export UPSTREAM_URL="${UPSTREAM_URL:-}"
export FORCE_CHROOT_REBUILD="${FORCE_CHROOT_REBUILD:-0}"
CONFIG_VARS

    # Append EXTRA_REPOS safely - properly quote multi-line content
    printf "\n# Extra repositories (properly handles multi-line values)\n" >> "${config_file}"
    printf "export EXTRA_REPOS=%q\n" "${EXTRA_REPOS:-}" >> "${config_file}"

    # Debug: Show generated config file (can be removed later)
    log_info "Generated config file: ${config_file}"
    log_info "Config file contents:"
    cat "${config_file}" | sed 's/^/  /' >&2

    chmod 644 "${config_file}"

    log_build "[docker-sbuild:PG] ${package} -> ${distro}/${arch} (PG ${pg_full})"
    log_info  "Persistent chroot (mmdebstrap tarball cache on volume: ${chroot_vol})"
    log_info  "Image:   ${full_image}"
    log_info  "Workdir: ${container_workdir}"
    log_info  "Output:  ${build_dir}"

    ${DOCKER_CMD} run -i --rm \
        --privileged \
        -v "${BUILDENV_PROJECT_ROOT}:/build:ro" \
        -v "${build_dir}:/output:rw" \
        -v "${chroot_vol}:/var/cache/sbuild:rw" \
        -v "${config_file}:/docker-sbuild.conf:ro" \
        -w "${container_workdir}" \
        -e HOME=/home/builder \
        --user root \
        "${full_image}" \
        bash -euo pipefail -s <<'CONTAINER_SCRIPT' 2>&1 | tee "${log_file}"
set -euo pipefail

# Source the build configuration file (loads DIST, ARCH, PG_VERSION, etc.)
source /docker-sbuild.conf

RED="\033[0;31m"; GRN="\033[0;32m"; YLW="\033[1;33m"; CYN="\033[0;36m"; NC="\033[0m"
log()  { echo -e "${GRN}[build]${NC} $*"; }
info() { echo -e "${CYN}[build]${NC} $*"; }
warn() { echo -e "${YLW}[build] WARN:${NC} $*"; }
die()  { echo -e "${RED}[build] ERROR:${NC} $*" >&2; exit 1; }

# Ensure /etc/schroot/chroot.d is writable (remove and recreate to clear any permission issues)
# This must be done BEFORE any schroot operations
if [[ -d /etc/schroot/chroot.d ]]; then
  rmdir /etc/schroot/chroot.d 2>/dev/null || {
    find /etc/schroot/chroot.d -type f -exec rm -f {} \; 2>/dev/null || true
    rm -rf /etc/schroot/chroot.d 2>/dev/null || true
  }
fi
mkdir -p /etc/schroot/chroot.d || die "Failed to create /etc/schroot/chroot.d"

# STEP 1 — Validate inputs
log "Step 1/10 · Validating inputs..."
: "${PG_VERSION:?PG_VERSION is required}"
: "${DIST:?DIST is required}"
: "${ARCH:?ARCH is required}"

PG_MAJOR="${PG_MAJOR:-${PG_VERSION%%.*}}"
DEB_SRC_NAME="postgresql-${PG_MAJOR}"

SCRIPT_DIR="$(pwd)"
DEBIAN_DIR="${SCRIPT_DIR}/debian"
OUTPUT_DIR="/output"
WORK_DIR="$(mktemp -d /tmp/pg-build-XXXXXX)"
CHROOT_CACHE="/var/cache/sbuild"
CHROOT_NAME="${DIST}-${ARCH}-sbuild"
CHROOT_TAR="${CHROOT_CACHE}/${CHROOT_NAME}.tar.gz"

trap 'log "Cleaning up ${WORK_DIR}..."; rm -rf "${WORK_DIR}"' EXIT
mkdir -p "${OUTPUT_DIR}" "${CHROOT_CACHE}"

info "  PG version    : ${PG_VERSION} (major ${PG_MAJOR})"
info "  Distribution  : ${DIST}"
info "  Architecture  : ${ARCH}"
info "  Source package: ${DEB_SRC_NAME}"
info "  Chroot tarball: ${CHROOT_TAR}"
info "  Output dir    : ${OUTPUT_DIR}"
echo ""

# STEP 2 — Verify debian/ layout
log "Step 2/10 · Verifying debian/ layout..."
[[ -d  "${DEBIAN_DIR}" ]]               || die "debian/ not found in ${SCRIPT_DIR}"
[[ -f  "${DEBIAN_DIR}/changelog" ]]     || die "debian/changelog missing"
[[ -f  "${DEBIAN_DIR}/control" ]]       || die "debian/control missing"
[[ -f  "${DEBIAN_DIR}/rules" ]]         || die "debian/rules missing"
[[ -f  "${DEBIAN_DIR}/source/format" ]] || die "debian/source/format missing"

SOURCE_FORMAT="$(cat "${DEBIAN_DIR}/source/format")"
[[ "${SOURCE_FORMAT}" == "3.0 (quilt)" ]] \
  || die "debian/source/format must be \"3.0 (quilt)\", found: \"${SOURCE_FORMAT}\""

CL_VERSION="$(dpkg-parsechangelog --file "${DEBIAN_DIR}/changelog" -S Version)"
CL_DIST="$(dpkg-parsechangelog    --file "${DEBIAN_DIR}/changelog" -S Distribution)"
info "  changelog version     : ${CL_VERSION}"
info "  changelog distribution: ${CL_DIST}"
if [[ "${CL_DIST}" != "${DIST}" && "${CL_DIST}" != "UNRELEASED" ]]; then
  warn "changelog targets \"${CL_DIST}\" but DIST=\"${DIST}\" — proceeding anyway"
fi

# STEP 3 — Confirm toolchain
log "Step 3/10 · Confirming toolchain..."
for tool in sbuild mmdebstrap schroot dpkg-buildpackage quilt lintian curl gpg wget; do
  command -v "${tool}" &>/dev/null && info "  ✓ ${tool}" || die "${tool} not found in image"
done

# STEP 4 — Chroot management
log "Step 4/10 · Chroot management..."

_create_chroot() {
  log "  Creating chroot with mmdebstrap..."

  local ubuntu_dists="focal jammy mantic noble plucky"
  local mirror components keyring_opt=""

  if echo "${ubuntu_dists}" | grep -qw "${DIST}"; then
    mirror="http://archive.ubuntu.com/ubuntu"
    components="main,restricted,universe,multiverse"
    info "  Distro family: Ubuntu (${DIST})"

    # Let mmdebstrap use system keyring
    keyring_opt="--keyring=/usr/share/keyrings/ubuntu-archive-keyring.gpg"

  else
    mirror="http://deb.debian.org/debian"
    components="main,contrib,non-free,non-free-firmware"
    info "  Distro family: Debian (${DIST})"
  fi

  eatmydata mmdebstrap \
    --variant=buildd \
    --arch="${ARCH}" \
    --components="${components}" \
    --include="apt-utils,ca-certificates,fakeroot,eatmydata,libipc-run-perl" \
    --setup-hook='mkdir -p "$1/etc"; echo "nameserver 1.1.1.1" > "$1/etc/resolv.conf"' \
    ${keyring_opt} \
    "${DIST}" \
    "${CHROOT_TAR}" \
    "${mirror}"
}

_register_chroot() {
  local chroot_config="/etc/schroot/chroot.d/${CHROOT_NAME}"

  # Remove any existing config file to avoid conflicts
  [[ -f "$chroot_config" ]] && rm -f "$chroot_config"

  # Write the configuration file directly
  # Note: directory was cleaned and prepared at container startup
  sudo tee "$chroot_config" > /dev/null <<EOF
[${CHROOT_NAME}]
description=Mydbops build chroot – ${DIST}/${ARCH}
type=file
file=${CHROOT_TAR}
groups=root,sbuild
root-groups=root,sbuild
profile=sbuild
EOF

  # Verify the file was written successfully
  [[ -f "$chroot_config" ]] || die "Failed to write schroot config at $chroot_config"
}

_refresh_chroot_apt() {
  log "  Refreshing apt lists inside chroot..."
  schroot -c "source:${CHROOT_NAME}" -u root -d / -- apt-get update -qq
}

if [[ "${FORCE_CHROOT_REBUILD}" == "1" ]]; then
  warn "FORCE_CHROOT_REBUILD=1 — removing existing chroot tarball."
  rm -f "${CHROOT_TAR}"
fi

if [[ -f "${CHROOT_TAR}" ]]; then
  info "  Reusing cached chroot: ${CHROOT_TAR}"
  _register_chroot
  # _refresh_chroot_apt
else
  info "  No cached chroot found for ${CHROOT_NAME}."
  _create_chroot
  _register_chroot
fi

schroot -c "source:${CHROOT_NAME}" -u root -d / -- /bin/true \
  || die "schroot smoke-test failed — re-run with FORCE_CHROOT_REBUILD=1."
info "  Chroot ready ✓"

# STEP 5 — Extra repos (safe multiline)
log "Step 5/10 · Extra repositories..."
EXTRA_REPO_ARGS=()
if [[ -n "${EXTRA_REPOS:-}" ]]; then
  while IFS= read -r repo_line; do
    repo_line="${repo_line#"${repo_line%%[![:space:]]*}"}"
    repo_line="${repo_line%"${repo_line##*[![:space:]]}"}"
    [[ -z "${repo_line}" || "${repo_line}" == \#* ]] && continue
    info "  + ${repo_line}"
    EXTRA_REPO_ARGS+=(--extra-repository="${repo_line}")
  done <<< "${EXTRA_REPOS}"
else
  info "  None."
fi

cd "${WORK_DIR}"

# STEP 6 — Fetch upstream tarball
log "Step 6/10 · Fetching upstream tarball..."
ORIG_TARBALL="${WORK_DIR}/${DEB_SRC_NAME}_${PG_VERSION}.orig.tar.gz"
DEFAULT_URL="https://ftp.postgresql.org/pub/source/v${PG_VERSION}/postgresql-${PG_VERSION}.tar.gz"
URL="${UPSTREAM_URL:-${DEFAULT_URL}}"

info "  URL : ${URL}"
info "  Dest: ${ORIG_TARBALL}"
wget --quiet --show-progress --output-document="${ORIG_TARBALL}" "${URL}" \
  || die "Download failed: ${URL}"

UPSTREAM_SRC="${WORK_DIR}/postgresql-${PG_VERSION}"

mkdir -p "${UPSTREAM_SRC}"

log "  Upstream source: ${UPSTREAM_SRC}"
log "  Overlaying debian/ from repo..."

cp -avLr "${DEBIAN_DIR}" "${UPSTREAM_SRC}/debian"

# STEP 8 — Quilt + source package
log "Step 8/10 · Building source package (.dsc)..."
NPROC="$(nproc 2>/dev/null || echo 4)"

cd "${UPSTREAM_SRC}"

ls -lA ${WORK_DIR}

log "  Current directory: "
ls -lA 

export DEB_BUILD_OPTIONS="parallel=${MAKE_JOBS:-${NPROC}} nocheck"
export DEB_BUILD_MAINT_OPTIONS="${DEB_BUILD_MAINT_OPTIONS:-hardening=+all}"

if [[ -f debian/patches/series ]] && grep -qE '^[^#[:space:]]' debian/patches/series 2>/dev/null; then
  info "  Applying quilt patches..."
  export QUILT_PATCHES=debian/patches
  quilt push -a --fuzz=0 || warn "Some patches did not apply cleanly"
else
  info "  No patches to apply."
fi

dpkg-buildpackage -d --build=source --no-sign -sa -d \
  2>&1 | tee "${WORK_DIR}/dpkg-buildpackage-source.log"

DSC_FILE="$(ls "${WORK_DIR}/${DEB_SRC_NAME}_"*.dsc 2>/dev/null | head -1)"
[[ -n "${DSC_FILE}" ]] || die ".dsc not produced — see ${WORK_DIR}/dpkg-buildpackage-source.log"
log "  Source package: $(basename "${DSC_FILE}")"

# STEP 9 — sbuild
log "Step 9/10 · Running sbuild..."
BUILD_LOG="${OUTPUT_DIR}/${DEB_SRC_NAME}_${CL_VERSION}_${ARCH}.build"
export DEB_BUILD_OPTIONS="noautodbgsym nocheck"
sbuild \
  --dist="${DIST}" \
  --arch="${ARCH}" \
  --build-dir="${OUTPUT_DIR}/DEBS" \
  --verbose \
  "${EXTRA_REPO_ARGS[@]}" \
  "${DSC_FILE}" \
  2>&1 | tee "${BUILD_LOG}" || {
    warn "sbuild failed. Search log for errors:"
    echo "  grep -E \"error:|configure:|E:\" \"${BUILD_LOG}\" | head -40"
    die "sbuild exited with an error — see ${BUILD_LOG}"
  }

# STEP 10 — artifacts + lintian
log "Step 10/10 · Collecting artifacts..."
find "${WORK_DIR}" -maxdepth 1 \( \
  -name "*.dsc" -o -name "*.tar.*" -o -name "*.changes" -o -name "*.buildinfo" \
\) -exec mv -v {} "${OUTPUT_DIR}/DEBS" \; || true

CHANGES_FILE="$(ls "${OUTPUT_DIR}"/*.changes 2>/dev/null | head -1 || true)"
if [[ -n "${CHANGES_FILE}" ]]; then
  log "  Running lintian (informational)..."
  lintian --color=auto "${CHANGES_FILE}" || true
else
  warn "  No .changes file found — skipping lintian"
fi

echo ""
echo -e "${GRN}══════════════════════════════════════════════════${NC}"
log "Build complete 🎉"
echo -e "${GRN}══════════════════════════════════════════════════${NC}"
info "Artifacts in: ${OUTPUT_DIR}"
ls -lh "${OUTPUT_DIR}"/ | grep -E '\.(deb|ddeb|dsc|changes|buildinfo|build)$' || true
echo ""
CONTAINER_SCRIPT

    local exit_code=${PIPESTATUS[0]}
    if [[ $exit_code -eq 0 ]]; then
        log_success "[docker-sbuild] ${package} ${distro}/${arch} succeeded"
    else
        log_error   "[docker-sbuild] ${package} ${distro}/${arch} FAILED"
    fi
    return $exit_code
}


# ─── Shell ─────────────────────────────────────────────────────────────────

builder_docker_sbuild_shell() {
    local distro="${ARG_DISTRO:-bookworm}"
    local full_image
    full_image=$(_docker_ensure_image "$distro") || return 1

    log_info "Opening shell in Docker container"
    log_info "Distribution: ${distro}"

    ${DOCKER_CMD} run --rm -it \
        -v "${BUILDENV_PROJECT_ROOT}:/build" \
        -w "/build" \
        -e HOME=/home/builder \
        "$full_image" \
        /bin/bash
}

# ─── Setup ─────────────────────────────────────────────────────────────────

builder_docker_sbuild_setup() {
    local distro="${ARG_DISTRO:-bookworm}"
    local full_image
    full_image=$(_docker_ensure_image "$distro") || return 1

    log_info "Setting up sbuild + mmdebstrap for: ${distro}"
    log_info "This creates the mmdebstrap chroot (takes 5-15 minutes)..."
    echo ""

    ${DOCKER_CMD} run --rm -it \
        -v "${BUILDENV_PROJECT_ROOT}:/build" \
        -w "/build" \
        -e HOME=/home/builder \
        "$full_image" \
        bash -c "
            echo '═══════════════════════════════════════════════════════════'
            echo '  sbuild + mmdebstrap Setup'
            echo '═══════════════════════════════════════════════════════════'
            echo ''

            echo '─ Checking Tools'
            echo ''
            echo '  sbuild:'
            sbuild --version 2>&1 | head -3 || echo '    NOT FOUND'
            echo ''
            echo '  mmdebstrap:'
            mmdebstrap --version 2>&1 | head -1 || echo '    NOT FOUND'
            echo ''
            echo '  schroot:'
            schroot --version 2>&1 | head -1 || echo '    NOT FOUND'
            echo ''

            echo '─ Initializing mmdebstrap Chroot'
            echo ''
            CHROOT_NAME=\"${distro}-amd64-sbuild\"
            CHROOT_PATH=\"/srv/sbuild/\${CHROOT_NAME}\"

            if [ -d \"\${CHROOT_PATH}\" ]; then
                echo \"✓ Chroot already exists: \${CHROOT_NAME}\"
                SIZE=\$(du -sh \${CHROOT_PATH} 2>/dev/null | cut -f1)
                echo \"  Location: \${CHROOT_PATH}\"
                echo \"  Size: \${SIZE}\"
                echo \"  Chroot will be reused for faster builds\"
            else
                echo \"Creating chroot: \${CHROOT_NAME}\"
                echo \"Location: \${CHROOT_PATH}\"
                echo \"Method: mmdebstrap only (fast minimal installation)\"
                echo \"Variant: buildd\"
                echo ''
                echo \"Please wait, this takes 5-15 minutes...\"
                echo ''

                if ! command -v mmdebstrap &>/dev/null; then
                    echo \"ERROR: mmdebstrap is required but not found\"
                    echo \"Install with: apt install mmdebstrap\"
                    exit 1
                fi

                echo \"Creating sbuild chroot with mmdebstrap...\"
                # mmdebstrap with fakechroot mode for containerized environments
                mmdebstrap --mode=fakechroot \
                    --include=build-essential,fakeroot,devscripts,lintian \
                    \${distro} \${CHROOT_PATH} https://deb.debian.org/debian

                echo ''
                echo \"✓ Chroot created successfully\"
                SIZE=\$(du -sh \${CHROOT_PATH} | cut -f1)
                echo \"✓ Chroot size: \${SIZE}\"
            fi

            echo ''
            echo '─ Configuration'
            echo ''
            echo '  sbuild: uses mmdebstrap for fast chroot creation'
            echo '  Method: Direct mmdebstrap invocation (no debootstrap wrapper)'
            echo ''

            echo '═══════════════════════════════════════════════════════════'
            echo '  Ready for builds!'
            echo '═══════════════════════════════════════════════════════════'
        "
}

# ─── Clean ─────────────────────────────────────────────────────────────────

builder_docker_sbuild_clean() {
    local distro="${ARG_DISTRO:-bookworm}"
    local full_image
    full_image=$(_docker_ensure_image "$distro") || return 1

    log_info "Cleaning sbuild chroots"

    ${DOCKER_CMD} run --rm -it \
        -v "${BUILDENV_PROJECT_ROOT}:/build" \
        -w "/build" \
        -e HOME=/home/builder \
        "$full_image" \
        bash -c "
            if command -v sbuild-destroychroot &>/dev/null; then
                sbuild-destroychroot ${distro}-amd64-sbuild 2>/dev/null || true
            fi
            echo 'Chroots cleaned'
        "
}

export -f builder_docker_sbuild_check_deps
export -f builder_docker_sbuild_build_deb
export -f builder_docker_sbuild_shell
export -f builder_docker_sbuild_setup
export -f builder_docker_sbuild_clean
