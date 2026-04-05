#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# scripts/lib/rpm.sh — RPM package assembly and build helpers
#
# Requires: common.sh sourced first
# ─────────────────────────────────────────────────────────────────────────────

[[ -n "${_MYDBOPS_RPM_LOADED:-}" ]] && return 0
_MYDBOPS_RPM_LOADED=1

# assemble_rpm_structure <tarball> <packaging_dir> <work_dir>
#
# Creates a standard rpmbuild tree under work_dir/rpmbuild/:
#   SOURCES/  ← tarball + all auxiliary source files from rpm/main/
#   SPECS/    ← .spec file
#
# packaging_dir: the package's directory in pg-packaging, e.g.
#   .../packages/postgresql-14
assemble_rpm_structure() {
    local tarball="$1"
    local packaging_dir="$2"
    local work_dir="$3"

    local rpmbuild_dir="${work_dir}/rpmbuild"
    mkdir -p "${rpmbuild_dir}/"{BUILD,BUILDROOT,RPMS,SOURCES,SPECS,SRPMS}

    local rpm_main="${packaging_dir}/rpm/main"
    if [[ ! -d "$rpm_main" ]]; then
        log_error "rpm/main not found in: $packaging_dir"
        return 1
    fi

    log_step "Copying tarball to SOURCES/"
    cp "$tarball" "${rpmbuild_dir}/SOURCES/"

    log_step "Copying spec file to SPECS/"
    local spec_file
    spec_file=$(find "$rpm_main" -maxdepth 1 -name '*.spec' | head -1)
    if [[ -z "$spec_file" ]]; then
        log_error "No .spec file found in: $rpm_main"
        return 1
    fi
    cp "$spec_file" "${rpmbuild_dir}/SPECS/"

    log_step "Copying auxiliary source files to SOURCES/"
    # Copy all non-spec, non-tarball files from rpm/main/ into SOURCES/
    # These include Source4-Source20: setup scripts, systemd units, patches, PAM files, etc.
    find "$rpm_main" -maxdepth 1 -type f \
        ! -name '*.spec' \
        ! -name 'Makefile' \
        -exec cp {} "${rpmbuild_dir}/SOURCES/" \;

    log_success "RPM build tree assembled in: $rpmbuild_dir"
}

# build_rpm <pkg> <version> <work_dir> <output_dir> <docker_image> [pg_major]
#
# Runs rpmbuild -bb inside the Docker image, copies .rpm files (no SRPMs) to output_dir.
# Sets global BUILT_RPMS array.
#
# pg_major: required for PostgreSQL packages (e.g. "14"). Passed as rpmbuild --define
# macros that the PostgreSQL spec expects: pgmajorversion, pginstdir, pgpackageversion.
# Also used to download Source12 (documentation PDF) which the %prep section requires.
build_rpm() {
    local pkg="$1"
    local version="$2"
    local work_dir="$3"
    local output_dir="$4"
    local docker_image="$5"
    local pg_major="${6:-}"

    BUILT_RPMS=()
    mkdir -p "$output_dir"

    local rpmbuild_dir="${work_dir}/rpmbuild"
    local spec_file
    spec_file=$(find "${rpmbuild_dir}/SPECS" -name '*.spec' | head -1)
    local spec_basename
    spec_basename=$(basename "$spec_file")

    log_build "Building rpm: ${pkg} ${version} in ${docker_image}"

    # Build the --define flags for rpmbuild. PostgreSQL specs use pgmajorversion
    # in Name:, all Source filenames, all Patch filenames, and throughout the spec body.
    # Without these defines rpmbuild fails immediately on an undefined macro in Name:.
    local pg_defines=""
    if [[ -n "$pg_major" ]]; then
        pg_defines="--define 'pgmajorversion ${pg_major}' --define 'pginstdir /usr/pgsql-${pg_major}' --define 'pgpackageversion ${pg_major}'"
    fi

    docker run --rm \
        -v "${rpmbuild_dir}:/rpmbuild" \
        -v "${output_dir}:/build/output" \
        "$docker_image" \
        bash -c "
            set -euo pipefail

            # Download URL-based sources listed in the spec (e.g. documentation PDF).
            # The PostgreSQL spec %prep section copies Source12 (the PDF) into the
            # build tree with '%{__cp} -p %{SOURCE12} .' and then %files references
            # it with '%doc *-A4.pdf'. If it is missing, rpmbuild fails in %prep.
            #
            # Try spectool first (rpmdevtools); fall back to direct curl for the PDF.
            if command -v spectool &>/dev/null && [[ -n '${pg_major}' ]]; then
                spectool -g -S \\
                    --define 'pgmajorversion ${pg_major}' \\
                    --define 'pginstdir /usr/pgsql-${pg_major}' \\
                    --define 'pgpackageversion ${pg_major}' \\
                    --directory /rpmbuild/SOURCES/ \\
                    /rpmbuild/SPECS/${spec_basename} 2>&1 || true
            elif [[ -n '${pg_major}' ]]; then
                pdf_dest='/rpmbuild/SOURCES/postgresql-${pg_major}-A4.pdf'
                if [[ ! -f \"\$pdf_dest\" ]]; then
                    pdf_url='https://www.postgresql.org/files/documentation/pdf/${pg_major}/postgresql-${pg_major}-A4.pdf'
                    curl -fsSL --retry 3 --retry-delay 5 -o \"\$pdf_dest\" \"\$pdf_url\" 2>&1 || \
                        echo 'WARN: Could not download documentation PDF — build may fail if spec requires it' >&2
                fi
            fi

            rpmbuild -bb \\
                --define '_topdir /rpmbuild' \\
                ${pg_defines} \\
                /rpmbuild/SPECS/${spec_basename} 2>&1
            find /rpmbuild/RPMS -name '*.rpm' ! -name '*.src.rpm' \\
                -exec cp {} /build/output/ \\;
        "

    # Collect output
    while IFS= read -r -d '' rpm; do
        BUILT_RPMS+=("$rpm")
    done < <(find "$output_dir" -name '*.rpm' ! -name '*.src.rpm' -print0 2>/dev/null)

    if [[ ${#BUILT_RPMS[@]} -eq 0 ]]; then
        log_error "No .rpm files produced for ${pkg} ${version}"
        return 1
    fi
    log_success "Built ${#BUILT_RPMS[@]} rpm(s): $(basename "${BUILT_RPMS[@]}")"
}

# validate_rpm <rpm_file>
#
# Runs rpmlint (non-blocking, warn only) and rpm -qpil (blocking).
validate_rpm() {
    local rpm_file="$1"

    log_info "Validating: $(basename "$rpm_file")"

    # rpm -qpil is blocking — if this fails the package is corrupt
    if ! rpm -qpil "$rpm_file" &>/dev/null; then
        log_error "rpm -qpil failed: $(basename "$rpm_file") appears corrupt"
        return 1
    fi

    # rpmlint is non-blocking — warn only
    if command -v rpmlint &>/dev/null; then
        rpmlint "$rpm_file" 2>&1 | head -40 || true
    fi

    log_success "Validated: $(basename "$rpm_file")"
}
