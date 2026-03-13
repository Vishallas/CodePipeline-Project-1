#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# scripts/lib/deb.sh — Debian package assembly and build helpers
#
# Requires: common.sh sourced first
# ─────────────────────────────────────────────────────────────────────────────

[[ -n "${_MYDBOPS_DEB_LOADED:-}" ]] && return 0
_MYDBOPS_DEB_LOADED=1

# assemble_deb_structure <tarball> <packaging_dir> <work_dir> <os> <release>
#
# Sets up the debuild source tree in work_dir:
#   work_dir/src/          ← extracted tarball
#   work_dir/src/debian/   ← packaging from debian/main/debian/
#                            + overlay from debian/{codename}/  (if present)
#
# packaging_dir: the package's directory in mydbops-pg-packaging, e.g.
#   .../packages/postgresql-14
assemble_deb_structure() {
    local tarball="$1"
    local packaging_dir="$2"
    local work_dir="$3"
    local os="$4"
    local release="$5"

    local src_dir="${work_dir}/src"
    mkdir -p "$src_dir"

    log_step "Extracting tarball: $(basename "$tarball")"
    tar -xf "$tarball" --strip-components=1 -C "$src_dir"

    local debian_main="${packaging_dir}/debian/main/debian"
    if [[ ! -d "$debian_main" ]]; then
        log_error "debian/main/debian not found in: $packaging_dir"
        return 1
    fi

    log_step "Copying debian/ packaging files"
    cp -a "$debian_main" "${src_dir}/debian"

    # Apply dist-specific overlay if present
    local codename
    codename=$(release_to_codename "$os" "$release")
    local overlay_dir="${packaging_dir}/debian/${codename}"
    if [[ -d "$overlay_dir" ]]; then
        log_info "Applying ${codename} overlay from debian/${codename}/"
        cp -a "${overlay_dir}/." "${src_dir}/debian/"
    fi

    log_success "Deb source tree assembled in: $src_dir"
}

# build_deb <pkg> <version> <work_dir> <output_dir> <docker_image>
#
# Runs dpkg-buildpackage inside the Docker image, copies .deb files to output_dir.
# Sets global BUILT_DEBS array.
build_deb() {
    local pkg="$1"
    local version="$2"
    local work_dir="$3"
    local output_dir="$4"
    local docker_image="$5"

    BUILT_DEBS=()
    mkdir -p "$output_dir"

    local src_dir="${work_dir}/src"

    local make_jobs
    make_jobs=$(nproc 2>/dev/null || echo 4)

    log_build "Building deb: ${pkg} ${version} in ${docker_image} (${make_jobs} jobs)"

    # Notes on flags:
    # -b              binary-only build (no source package)
    # -us -uc         skip signing (handled separately via gpg_sign_deb)
    # -Pnocheck       disable PostgreSQL regression test suite (DEB_BUILD_PROFILES=nocheck).
    #                 Without this, debian/rules runs 'make check' which takes 30+ min
    #                 and fails in CI containers (hard exit 1 on test failure per rules).
    # src_dir is NOT mounted :ro — dpkg-buildpackage must write debian/files,
    # debian/*.debhelper.log, and build artifacts back into the source tree.
    docker run --rm \
        -v "${src_dir}:/build/src" \
        -v "${output_dir}:/build/output" \
        -e "DEB_BUILD_OPTIONS=parallel=${make_jobs}" \
        -e "MAKEFLAGS=-j${make_jobs}" \
        -w /build/src \
        "$docker_image" \
        bash -c "
            set -euo pipefail
            dpkg-buildpackage -us -uc -b -Pnocheck 2>&1
            mv ../*.deb /build/output/ 2>/dev/null || true
        "

    # Collect output
    while IFS= read -r -d '' deb; do
        BUILT_DEBS+=("$deb")
    done < <(find "$output_dir" -name '*.deb' -print0 2>/dev/null)

    if [[ ${#BUILT_DEBS[@]} -eq 0 ]]; then
        log_error "No .deb files produced for ${pkg} ${version}"
        return 1
    fi
    log_success "Built ${#BUILT_DEBS[@]} deb(s): $(basename "${BUILT_DEBS[@]}")"
}

# validate_deb <deb_file>
#
# Runs lintian (non-blocking, warn only) and dpkg-deb --info (blocking).
validate_deb() {
    local deb_file="$1"

    log_info "Validating: $(basename "$deb_file")"

    # dpkg-deb --info is blocking — if this fails the package is corrupt
    if ! dpkg-deb --info "$deb_file" &>/dev/null; then
        log_error "dpkg-deb --info failed: $(basename "$deb_file") is corrupt"
        return 1
    fi

    # lintian is non-blocking — we only warn, never fail
    if command -v lintian &>/dev/null; then
        lintian "$deb_file" 2>&1 | head -40 || true
    fi

    log_success "Validated: $(basename "$deb_file")"
}
