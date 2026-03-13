#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# scripts/build-package.sh — Main entry point for all package builds
#
# Called by every CodeBuild buildspec and can be run locally for development.
#
# Usage:
#   build-package.sh --package NAME --packages-dir DIR --s3-bucket BUCKET \
#                    --env staging [--os ubuntu] [--release 22] [--arch amd64]
#   build-package.sh --all --packages-dir DIR --s3-bucket BUCKET --env staging
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/deb.sh"
source "${SCRIPT_DIR}/lib/rpm.sh"
source "${SCRIPT_DIR}/lib/pulp.sh"

# ─── Argument parsing ─────────────────────────────────────────────────────────

PACKAGE_NAME=""
PACKAGES_DIR=""
S3_BUCKET=""
BUILD_ENV=""
CLI_OS=""
CLI_RELEASE=""
CLI_ARCH=""
BUILD_ALL=0

while [[ $# -gt 0 ]]; do
    case $1 in
        --package)      PACKAGE_NAME="$2";  shift 2 ;;
        --packages-dir) PACKAGES_DIR="$2";  shift 2 ;;
        --s3-bucket)    S3_BUCKET="$2";     shift 2 ;;
        --env)          BUILD_ENV="$2";     shift 2 ;;
        --os)           CLI_OS="$2";        shift 2 ;;
        --release)      CLI_RELEASE="$2";   shift 2 ;;
        --arch)         CLI_ARCH="$2";      shift 2 ;;
        --all)          BUILD_ALL=1;        shift ;;
        *) log_error "Unknown argument: $1"; exit 1 ;;
    esac
done

# ─── Validate required args ───────────────────────────────────────────────────

if [[ $BUILD_ALL -eq 0 && -z "$PACKAGE_NAME" ]]; then
    log_error "Either --package NAME or --all is required"
    exit 1
fi
if [[ -z "$PACKAGES_DIR" || -z "$S3_BUCKET" || -z "$BUILD_ENV" ]]; then
    log_error "--packages-dir, --s3-bucket, and --env are required"
    exit 1
fi
if [[ "$BUILD_ENV" != "staging" && "$BUILD_ENV" != "production" ]]; then
    log_error "--env must be 'staging' or 'production'"
    exit 1
fi

check_deps docker aws curl python3

# Resolve packages dir to absolute path
PACKAGES_DIR="$(cd "$PACKAGES_DIR" && pwd)"

# ─── Load ECR config ──────────────────────────────────────────────────────────

PLATFORM_DIR="$(dirname "$SCRIPT_DIR")"
REPOS_YML="${PLATFORM_DIR}/config/repos.yml"

ECR_REGION="${ECR_REGION:-$(yaml_get "$REPOS_YML" 'ecr.region')}"
ECR_ACCOUNT_ID="${ECR_ACCOUNT_ID:-$(yaml_get "$REPOS_YML" 'ecr.account_id')}"
ECR_REPO="${ECR_REPO:-$(yaml_get "$REPOS_YML" 'ecr.repository')}"
PULP_URL="${PULP_URL:-$(yaml_get "$REPOS_YML" 'pulp.url')}"
export PULP_URL

# ─── GPG setup (once per invocation) ─────────────────────────────────────────

GPG_KEY_ID=""
GPG_SECRET_NAME="${GPG_SECRET_NAME:-$(yaml_get "$REPOS_YML" 'gpg.key_secret')}"
if [[ -n "$GPG_SECRET_NAME" && "$GPG_SECRET_NAME" != "null" ]]; then
    GPG_PRIVATE_KEY="${GPG_PRIVATE_KEY:-$(secrets_manager_get "$GPG_SECRET_NAME" 2>/dev/null || true)}"
    if [[ -n "${GPG_PRIVATE_KEY:-}" ]]; then
        gpg_import_key "$GPG_PRIVATE_KEY"
        gpg_setup_rpmmacros "$GPG_KEY_ID"
    fi
fi
export GPG_KEY_ID

# ─── Per-package build logic ──────────────────────────────────────────────────

build_package() {
    local pkg_name="$1"
    local pkg_dir="${PACKAGES_DIR}/packages/${pkg_name}"
    local metadata="${pkg_dir}/METADATA.yml"
    local build_yml="${pkg_dir}/build.yml"

    if [[ ! -f "$metadata" ]]; then
        log_error "METADATA.yml not found: $metadata"
        return 1
    fi

    # Load package metadata
    local PKG_VERSION PKG_REVISION SOURCE_URL SOURCE_SHA256 PG_MAJOR
    PKG_VERSION=$(yaml_get "$metadata" 'package.version')
    PKG_REVISION=$(yaml_get "$metadata" 'package.revision')
    SOURCE_URL=$(yaml_get "$metadata" 'package.source_url')
    SOURCE_SHA256=$(yaml_get "$metadata" 'package.source_sha256')
    PG_MAJOR=$(yaml_get "$metadata" 'package.pg_major')

    log_step "=== Building: ${pkg_name} ${PKG_VERSION}-${PKG_REVISION} ==="

    # Determine target list
    # All three CLI args given → single explicit target, build.yml ignored.
    # Only --os (optionally --release/--arch) given → read build.yml then filter.
    # No CLI args → all enabled targets from build.yml.
    local targets=()
    if [[ -n "$CLI_OS" && -n "$CLI_RELEASE" && -n "$CLI_ARCH" ]]; then
        targets=("${CLI_OS}:${CLI_RELEASE}:${CLI_ARCH}")
    else
        if [[ ! -f "$build_yml" ]]; then
            log_error "build.yml not found: $build_yml"
            return 1
        fi
        # Parse enabled targets from build.yml via Python
        local all_targets=()
        mapfile -t all_targets < <(python3 - "$build_yml" <<'PYEOF'
import sys
import yaml

with open(sys.argv[1]) as f:
    data = yaml.safe_load(f)

for t in data.get('targets', []):
    if not t.get('enabled', False):
        continue
    os_name = t['os']
    release = str(t['release'])
    for arch in t.get('arch', []):
        print(f"{os_name}:{release}:{arch}")
PYEOF
        )
        # Apply CLI filters (--os / --release / --arch act as optional filters)
        for t in "${all_targets[@]}"; do
            IFS=':' read -r t_os t_release t_arch <<< "$t"
            [[ -n "$CLI_OS"      && "$t_os"      != "$CLI_OS"      ]] && continue
            [[ -n "$CLI_RELEASE" && "$t_release" != "$CLI_RELEASE" ]] && continue
            [[ -n "$CLI_ARCH"    && "$t_arch"    != "$CLI_ARCH"    ]] && continue
            targets+=("$t")
        done
    fi

    if [[ ${#targets[@]} -eq 0 ]]; then
        log_warn "No enabled targets for ${pkg_name}"
        return 0
    fi

    # Download tarball once for all targets
    local work_base
    work_base=$(mktemp -d "/tmp/build-${pkg_name}-XXXX")
    trap "rm -rf '$work_base'" EXIT

    local tarball_path="${work_base}/$(basename "$SOURCE_URL")"
    download_tarball "$SOURCE_URL" "$tarball_path" "${SOURCE_SHA256:-}"

    # ECR login (once per build_package call if ECR is configured)
    if [[ -n "$ECR_ACCOUNT_ID" && "$ECR_ACCOUNT_ID" != "null" && \
          -n "$ECR_REGION" && "$ECR_REGION" != "null" ]]; then
        ecr_login "$ECR_REGION" "$ECR_ACCOUNT_ID"
    fi

    # Per-target loop
    local FAILED_TARGETS=()

    for target_str in "${targets[@]}"; do
        IFS=':' read -r t_os t_release t_arch <<< "$target_str"

        # When CLI gave --os without --release/--arch, build all arch combos
        # The targets array already has explicit triples from build.yml or CLI

        local s3_label
        s3_label=$(target_to_s3_label "$t_os" "$t_release" "$t_arch") || continue

        local docker_tag
        docker_tag=$(target_to_docker_tag "$t_os" "$t_release" "$t_arch") || {
            log_error "Unknown target: ${t_os}-${t_release}-${t_arch}"
            FAILED_TARGETS+=("${s3_label}")
            continue
        }

        local pkg_type
        pkg_type=$(target_pkg_type "$t_os")

        local docker_image
        if [[ -n "$ECR_ACCOUNT_ID" && "$ECR_ACCOUNT_ID" != "null" ]]; then
            docker_image=$(ecr_image_uri "$ECR_ACCOUNT_ID" "$ECR_REGION" "$ECR_REPO" "$docker_tag")
        else
            docker_image="mydbops/pg-build:${docker_tag}"
        fi

        local target_work="${work_base}/${s3_label}"
        local output_dir="${target_work}/output"
        mkdir -p "$output_dir"

        log_step "--- Target: ${s3_label} ---"

        # Assemble and build (errors captured, loop continues)
        if ! (
            set -e
            if [[ "$pkg_type" == "deb" ]]; then
                assemble_deb_structure "$tarball_path" "$pkg_dir" "$target_work" "$t_os" "$t_release"
                build_deb "$pkg_name" "$PKG_VERSION" "$target_work" "$output_dir" "$docker_image"
            else
                assemble_rpm_structure "$tarball_path" "$pkg_dir" "$target_work"
                build_rpm "$pkg_name" "$PKG_VERSION" "$target_work" "$output_dir" "$docker_image" "$PG_MAJOR"
            fi
        ); then
            log_error "Build failed for target: ${s3_label}"
            FAILED_TARGETS+=("$s3_label")
            continue
        fi

        # Post-build: validate, sign, upload
        local artifacts=()
        if [[ "$pkg_type" == "deb" ]]; then
            artifacts=("${BUILT_DEBS[@]}")
        else
            artifacts=("${BUILT_RPMS[@]}")
        fi

        for artifact in "${artifacts[@]}"; do
            local s3_path
            s3_path=$(s3_build_path "$S3_BUCKET" "$BUILD_ENV" "$pkg_name" "${PKG_VERSION}-${PKG_REVISION}" "$s3_label")/$(basename "$artifact")

            # Validate
            if [[ "$pkg_type" == "deb" ]]; then
                validate_deb "$artifact" || { log_warn "Validation issues for $(basename "$artifact")"; }
                gpg_sign_deb "$artifact" "$GPG_KEY_ID"
            else
                validate_rpm "$artifact" || { log_warn "Validation issues for $(basename "$artifact")"; }
                gpg_sign_rpm "$artifact" "$GPG_KEY_ID"
            fi

            # Upload to S3
            if ! s3_upload "$artifact" "$s3_path"; then
                log_error "S3 upload failed: $(basename "$artifact")"
                FAILED_TARGETS+=("$s3_label")
                continue
            fi

            # Pulp (non-blocking)
            local pulp_repo="${pkg_name}-${s3_label}"
            pulp_sync_after_upload "$pkg_name" "${PKG_VERSION}-${PKG_REVISION}" "$pkg_type" "$pulp_repo"
        done
    done

    if [[ ${#FAILED_TARGETS[@]} -gt 0 ]]; then
        log_error "Failed targets for ${pkg_name}: ${FAILED_TARGETS[*]}"
        return 1
    fi

    log_success "=== ${pkg_name} ${PKG_VERSION}-${PKG_REVISION}: all targets complete ==="
}

# ─── Main ─────────────────────────────────────────────────────────────────────

if [[ $BUILD_ALL -eq 1 ]]; then
    # Build all packages in packages-dir
    OVERALL_FAILED=()
    for metadata_file in "${PACKAGES_DIR}"/packages/*/METADATA.yml; do
        pkg_dir=$(dirname "$metadata_file")
        pkg=$(basename "$pkg_dir")
        build_package "$pkg" || OVERALL_FAILED+=("$pkg")
    done
    if [[ ${#OVERALL_FAILED[@]} -gt 0 ]]; then
        log_error "Failed packages: ${OVERALL_FAILED[*]}"
        exit 1
    fi
else
    build_package "$PACKAGE_NAME"
fi
