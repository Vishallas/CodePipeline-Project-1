#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# scripts/manage-build-images.sh — Build, push, pull, and inspect ECR images
#
# Supports building both amd64 and arm64 images on a single host machine using
# Docker buildx with QEMU cross-architecture emulation. Run 'setup-builder'
# once before the first build, then 'build' builds all arch variants locally.
#
# Usage:
#   manage-build-images.sh <command> [--target TAG] [--pg-versions "14 15 16 17"]
#
# Commands:
#   setup-builder       Install QEMU emulators + create persistent buildx builder.
#                       Run this once on a new machine before the first build.
#   build      [--target TAG]  Build one or all images locally (both arches on one host)
#   push       [--target TAG]  Push one or all images to ECR
#   build-push [--target TAG]  Build then immediately push (atomic for CI use)
#   pull       [--target TAG]  Pull one or all images from ECR
#   list                       List all images with ECR metadata (pushed date, digest, size, scan)
#   inspect    --target TAG    Deep-dive: full digest, labels, scan findings breakdown
#   scan       [--target TAG]  Trigger ECR vulnerability scan
#   login                      ECR docker login only
#
# Options:
#   --target TAG        One image tag, e.g. ubuntu-22.04-amd64
#                       Omit to run command on ALL images
#   --pg-versions LIST  Space-separated PG majors to embed (default: "14 15 16 17")
#   --account ID        AWS account ID (or set ECR_ACCOUNT_ID env)
#   --region  REGION    AWS region    (or set ECR_REGION env)
#   --repo    REPO      ECR repo name (default: pg-platform/pg-build)
#   --no-cache          Pass --no-cache to docker buildx build (force full rebuild)
#   --dry-run           Print commands without executing
#
# How cross-arch builds work on one host:
#   Docker buildx + QEMU allows building arm64 images on an amd64 host (and
#   vice versa) via CPU instruction emulation. The first build of a cross-arch
#   image is slower (QEMU overhead) but the result is a fully functional image
#   that the target architecture can run natively after pulling from ECR.
#
#   The 'setup-builder' command:
#     1. Installs QEMU binfmt_misc handlers for all architectures
#        (uses tonistiigi/binfmt — the standard Docker multi-arch tool)
#     2. Creates a named buildx builder 'pg-platform-builder' using the
#        docker-container driver, which unlike the default 'docker' driver
#        supports --load for cross-arch single-platform images
#
#   After setup, 'build' runs each image in the manifest against its declared
#   platform (linux/amd64 or linux/arm64). Cross-arch targets are built via
#   QEMU and loaded into the local Docker daemon with --load, ready for
#   inspection and pushing.
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

# ─── Defaults ─────────────────────────────────────────────────────────────────

PLATFORM_DIR="$(dirname "$SCRIPT_DIR")"
REPOS_YML="${PLATFORM_DIR}/config/repos.yml"
DOCKER_DIR="${PLATFORM_DIR}/docker"

ECR_ACCOUNT_ID="${ECR_ACCOUNT_ID:-$(yaml_get "$REPOS_YML" 'ecr.account_id' 2>/dev/null || true)}"
ECR_REGION="${ECR_REGION:-$(yaml_get "$REPOS_YML" 'ecr.region' 2>/dev/null || echo 'us-east-1')}"
ECR_REPO="${ECR_REPO:-$(yaml_get "$REPOS_YML" 'ecr.repository' 2>/dev/null || echo 'pg-platform/pg-build')}"
PG_VERSIONS="${PG_VERSIONS:-14 15 16 17}"

CMD=""
TARGET=""
DRY_RUN=0
NO_CACHE=0
BUILDX_BUILDER="pg-platform-builder"

# ─── Image manifest ───────────────────────────────────────────────────────────
#
# Format: TAG|DOCKERFILE|BUILD_ARGS|PLATFORM
# BUILD_ARGS uses ~ as separator (avoids shell quoting issues with spaces)
#
declare -A IMAGE_DOCKERFILE IMAGE_BUILDARGS IMAGE_PLATFORM

_reg() {
    local tag="$1" dockerfile="$2" buildargs="$3" platform="${4:-linux/amd64}"
    IMAGE_DOCKERFILE[$tag]="$dockerfile"
    IMAGE_BUILDARGS[$tag]="$buildargs"
    IMAGE_PLATFORM[$tag]="$platform"
}

_reg "ubuntu-20.04-amd64"  "Dockerfile.ubuntu"  "UBUNTU_VERSION=20.04"        "linux/amd64"
_reg "ubuntu-22.04-amd64"  "Dockerfile.ubuntu"  "UBUNTU_VERSION=22.04"        "linux/amd64"
_reg "ubuntu-22.04-arm64"  "Dockerfile.ubuntu"  "UBUNTU_VERSION=22.04"        "linux/arm64"
_reg "ubuntu-24.04-amd64"  "Dockerfile.ubuntu"  "UBUNTU_VERSION=24.04"        "linux/amd64"
_reg "ubuntu-24.04-arm64"  "Dockerfile.ubuntu"  "UBUNTU_VERSION=24.04"        "linux/arm64"
_reg "el8-x86_64"          "Dockerfile.el"      "EL_VERSION=8"                "linux/amd64"
_reg "el8-aarch64"         "Dockerfile.el"      "EL_VERSION=8"                "linux/arm64"
_reg "el9-x86_64"          "Dockerfile.el"      "EL_VERSION=9"                "linux/amd64"
_reg "el9-aarch64"         "Dockerfile.el"      "EL_VERSION=9"                "linux/arm64"
_reg "el10-x86_64"         "Dockerfile.el"      "EL_VERSION=10"               "linux/amd64"
_reg "fedora-42-x86_64"    "Dockerfile.fedora"  "FEDORA_VERSION=42"           "linux/amd64"
_reg "fedora-43-x86_64"    "Dockerfile.fedora"  "FEDORA_VERSION=43"           "linux/amd64"

ALL_TAGS=(
    ubuntu-20.04-amd64
    ubuntu-22.04-amd64 ubuntu-22.04-arm64
    ubuntu-24.04-amd64 ubuntu-24.04-arm64
    el8-x86_64 el8-aarch64
    el9-x86_64 el9-aarch64
    el10-x86_64
    fedora-42-x86_64 fedora-43-x86_64
)

# ─── Argument parsing ─────────────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
    case $1 in
        setup-builder|build|build-push|push|pull|list|inspect|scan|login) CMD="$1"; shift ;;
        --target)      TARGET="$2";      shift 2 ;;
        --pg-versions) PG_VERSIONS="$2"; shift 2 ;;
        --account)     ECR_ACCOUNT_ID="$2"; shift 2 ;;
        --region)      ECR_REGION="$2";  shift 2 ;;
        --repo)        ECR_REPO="$2";    shift 2 ;;
        --no-cache)    NO_CACHE=1;       shift ;;
        --dry-run)     DRY_RUN=1;        shift ;;
        *) log_error "Unknown argument: $1"; exit 1 ;;
    esac
done

if [[ -z "$CMD" ]]; then
    echo "Usage: manage-build-images.sh <setup-builder|build|build-push|push|pull|list|inspect|scan|login> [options]"
    exit 1
fi

# ─── Helpers ──────────────────────────────────────────────────────────────────

ecr_uri() {
    echo "${ECR_ACCOUNT_ID}.dkr.ecr.${ECR_REGION}.amazonaws.com/${ECR_REPO}"
}

full_image() {
    echo "$(ecr_uri):$1"
}

run_cmd() {
    if [[ $DRY_RUN -eq 1 ]]; then
        echo "[dry-run] $*"
    else
        "$@"
    fi
}

require_ecr_account() {
    if [[ -z "$ECR_ACCOUNT_ID" || "$ECR_ACCOUNT_ID" == "null" ]]; then
        log_error "ECR account ID not set. Use --account or set ECR_ACCOUNT_ID"
        exit 1
    fi
}

# ─── Commands ─────────────────────────────────────────────────────────────────

cmd_setup_builder() {
    log_step "Installing QEMU binfmt_misc handlers"
    run_cmd docker run --privileged --rm tonistiigi/binfmt --install all

    log_step "Creating buildx builder '${BUILDX_BUILDER}' (docker-container driver)"
    if docker buildx inspect "$BUILDX_BUILDER" &>/dev/null; then
        log_info "Builder '${BUILDX_BUILDER}' already exists — skipping create"
    else
        run_cmd docker buildx create \
            --name "$BUILDX_BUILDER" \
            --driver docker-container \
            --bootstrap \
            --use
    fi

    log_success "Builder ready: ${BUILDX_BUILDER}"
    log_info "Run 'build' to build images for all platforms"
}

# ensure_builder — called automatically by cmd_build; idempotent
ensure_builder() {
    if ! docker buildx inspect "$BUILDX_BUILDER" &>/dev/null; then
        log_warn "Builder '${BUILDX_BUILDER}' not found — run 'setup-builder' first"
        log_warn "Falling back to: docker buildx create --name ${BUILDX_BUILDER} --driver docker-container --bootstrap --use"
        docker buildx create \
            --name "$BUILDX_BUILDER" \
            --driver docker-container \
            --bootstrap \
            --use
    fi
}

cmd_login() {
    require_ecr_account
    log_step "ECR login: $(ecr_uri)"
    run_cmd aws ecr get-login-password --region "$ECR_REGION" \
        | docker login --username AWS --password-stdin "$(ecr_uri)"
    log_success "ECR login complete"
}

cmd_build() {
    ensure_builder

    local tags=("${ALL_TAGS[@]}")
    [[ -n "$TARGET" ]] && tags=("$TARGET")

    for tag in "${tags[@]}"; do
        if [[ -z "${IMAGE_DOCKERFILE[$tag]:-}" ]]; then
            log_error "Unknown image tag: $tag"
            exit 1
        fi

        local dockerfile="${DOCKER_DIR}/${IMAGE_DOCKERFILE[$tag]}"
        local platform="${IMAGE_PLATFORM[$tag]}"
        local local_tag="${ECR_REPO}:${tag}"
        local ecr_tag
        ecr_tag=$(full_image "$tag")

        # Build --build-arg flags
        local build_arg_flags=(--build-arg "PG_VERSIONS=${PG_VERSIONS}")
        IFS='~' read -ra extra_args <<< "${IMAGE_BUILDARGS[$tag]}"
        for arg in "${extra_args[@]}"; do
            [[ -n "$arg" ]] && build_arg_flags+=(--build-arg "$arg")
        done

        # Embed OCI provenance labels
        local build_date
        build_date=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
        local git_commit
        git_commit=$(git -C "$PLATFORM_DIR" rev-parse --short HEAD 2>/dev/null || echo "unknown")
        build_arg_flags+=(--build-arg "BUILD_DATE=${build_date}" --build-arg "GIT_COMMIT=${git_commit}")

        local no_cache_flag=()
        [[ $NO_CACHE -eq 1 ]] && no_cache_flag=(--no-cache)

        log_build "Building: ${tag}  [platform=${platform}]${NO_CACHE:+ (--no-cache)}"
        run_cmd docker buildx build \
            --builder "$BUILDX_BUILDER" \
            --platform "$platform" \
            "${build_arg_flags[@]}" \
            "${no_cache_flag[@]}" \
            -f "$dockerfile" \
            -t "$local_tag" \
            -t "$ecr_tag" \
            --load \
            "$PLATFORM_DIR"

        log_success "Built: ${tag}"
    done
}

cmd_push() {
    require_ecr_account
    cmd_login

    # Ensure ECR repository exists before the first push
    if [[ $DRY_RUN -eq 0 ]]; then
        if ! aws ecr describe-repositories \
                --repository-names "$ECR_REPO" \
                --region "$ECR_REGION" &>/dev/null; then
            log_step "ECR repository '${ECR_REPO}' not found — creating"
            aws ecr create-repository \
                --repository-name "$ECR_REPO" \
                --region "$ECR_REGION" \
                --image-scanning-configuration scanOnPush=true \
                --image-tag-mutability MUTABLE
            log_success "ECR repository created: ${ECR_REPO}"
        fi
    fi

    local tags=("${ALL_TAGS[@]}")
    [[ -n "$TARGET" ]] && tags=("$TARGET")

    for tag in "${tags[@]}"; do
        local ecr_tag
        ecr_tag=$(full_image "$tag")

        log_info "Pushing: ${tag}"
        run_cmd docker push "$ecr_tag"
        log_success "Pushed: ${tag}"
    done
}

cmd_build_push() {
    cmd_build
    cmd_push
}

cmd_pull() {
    require_ecr_account
    cmd_login

    local tags=("${ALL_TAGS[@]}")
    [[ -n "$TARGET" ]] && tags=("$TARGET")

    for tag in "${tags[@]}"; do
        local ecr_tag
        ecr_tag=$(full_image "$tag")

        log_info "Pulling: ${tag}"
        run_cmd docker pull "$ecr_tag"
        log_success "Pulled: ${tag}"
    done
}

cmd_list() {
    require_ecr_account

    printf "%-30s %-14s %-9s %-9s %-18s %-9s %-7s %s\n" \
        "TAG" "PLATFORM" "LOCAL" "ECR" "PUSHED" "DIGEST" "SIZE" "SCAN"
    printf "%-30s %-14s %-9s %-9s %-18s %-9s %-7s %s\n" \
        "---" "--------" "-----" "---" "------" "------" "----" "----"

    for tag in "${ALL_TAGS[@]}"; do
        local platform="${IMAGE_PLATFORM[$tag]}"

        local local_status="absent"
        docker image inspect "${ECR_REPO}:${tag}" &>/dev/null && local_status="present"

        # Query ECR for enriched metadata
        local ecr_json=""
        ecr_json=$(aws ecr describe-images \
            --repository-name "$ECR_REPO" \
            --region "$ECR_REGION" \
            --image-ids imageTag="$tag" \
            --query 'imageDetails[0]' \
            --output json 2>/dev/null || echo "null")

        local ecr_status pushed digest size scan
        if [[ "$ecr_json" == "null" || -z "$ecr_json" ]]; then
            ecr_status="absent"
            pushed="—"
            digest="—"
            size="—"
            scan="—"
        else
            ecr_status="present"
            pushed=$(echo "$ecr_json" | jq -r '
                if .imagePushedAt then
                    (.imagePushedAt | strftime("%Y-%m-%d %H:%M"))
                else "—" end' 2>/dev/null || echo "—")
            digest=$(echo "$ecr_json" | jq -r '
                if .imageDigest then
                    (.imageDigest | ltrimstr("sha256:") | .[0:7])
                else "—" end' 2>/dev/null || echo "—")
            size=$(echo "$ecr_json" | jq -r '
                if .imageSizeInBytes then
                    ((.imageSizeInBytes / 1048576) | floor | tostring) + "MB"
                else "—" end' 2>/dev/null || echo "—")
            scan=$(echo "$ecr_json" | jq -r '
                if .imageScanFindingsSummary.findingSeverityCounts then
                    ((.imageScanFindingsSummary.findingSeverityCounts.CRITICAL // 0 | tostring) + "C/" +
                     (.imageScanFindingsSummary.findingSeverityCounts.HIGH    // 0 | tostring) + "H")
                else "—" end' 2>/dev/null || echo "—")
        fi

        printf "%-30s %-14s %-9s %-9s %-18s %-9s %-7s %s\n" \
            "$tag" "$platform" "$local_status" "$ecr_status" \
            "$pushed" "$digest" "$size" "$scan"
    done
}

cmd_scan() {
    require_ecr_account

    local tags=("${ALL_TAGS[@]}")
    [[ -n "$TARGET" ]] && tags=("$TARGET")

    for tag in "${tags[@]}"; do
        log_info "Triggering ECR scan: ${tag}"
        run_cmd aws ecr start-image-scan \
            --repository-name "$ECR_REPO" \
            --region "$ECR_REGION" \
            --image-id imageTag="$tag" \
            2>/dev/null || log_warn "Scan trigger failed for ${tag} (may not exist in ECR)"
    done

    log_info "Scan results available in: AWS Console → ECR → ${ECR_REPO} → Images"
    log_info "Or: aws ecr describe-image-scan-findings --repository-name ${ECR_REPO} --image-id imageTag=<TAG>"
}

cmd_inspect() {
    require_ecr_account

    if [[ -z "$TARGET" ]]; then
        log_error "inspect requires --target TAG"
        exit 1
    fi

    local tag="$TARGET"

    # ── ECR image details ──────────────────────────────────────────────────
    log_step "Fetching ECR image details: ${tag}"
    local ecr_json=""
    ecr_json=$(aws ecr describe-images \
        --repository-name "$ECR_REPO" \
        --region "$ECR_REGION" \
        --image-ids imageTag="$tag" \
        --query 'imageDetails[0]' \
        --output json 2>/dev/null || echo "null")

    if [[ "$ecr_json" == "null" || -z "$ecr_json" ]]; then
        log_warn "Image '${tag}' not found in ECR — showing local inspect only"
    else
        echo ""
        echo "=== ECR image details: ${tag} ==="
        echo "$ecr_json" | jq -r '
            "  Full digest : " + (.imageDigest // "—"),
            "  Pushed at   : " + ((.imagePushedAt | strftime("%Y-%m-%dT%H:%M:%SZ")) // "—"),
            "  Size        : " + (if .imageSizeInBytes then
                                    ((.imageSizeInBytes / 1048576 * 10 | floor) / 10 | tostring) + " MB"
                                  else "—" end)'
    fi

    # ── Labels (from local docker inspect if present, else ECR config) ─────
    echo ""
    echo "=== OCI + pg-platform labels ==="
    if docker image inspect "${ECR_REPO}:${tag}" &>/dev/null; then
        docker image inspect "${ECR_REPO}:${tag}" \
            | jq -r '.[0].Config.Labels // {} | to_entries[] | "  \(.key) = \(.value)"'
    else
        log_info "Image not present locally — labels not available without pulling"
        log_info "Run: manage-build-images.sh pull --target ${tag}  then re-inspect"
    fi

    # ── ECR vulnerability scan findings ───────────────────────────────────
    echo ""
    echo "=== Vulnerability scan findings ==="
    local scan_json=""
    scan_json=$(aws ecr describe-image-scan-findings \
        --repository-name "$ECR_REPO" \
        --region "$ECR_REGION" \
        --image-id imageTag="$tag" \
        --output json 2>/dev/null || echo "null")

    if [[ "$scan_json" == "null" || -z "$scan_json" ]]; then
        log_info "No scan findings available (image may not be in ECR or scan not yet complete)"
    else
        local scan_status
        scan_status=$(echo "$scan_json" | jq -r '.imageScanStatus.status // "UNKNOWN"')
        echo "  Scan status: ${scan_status}"

        echo "$scan_json" | jq -r '
            .imageScanFindings.findingSeverityCounts // {} |
            to_entries | sort_by(
                if .key == "CRITICAL" then 0
                elif .key == "HIGH"   then 1
                elif .key == "MEDIUM" then 2
                elif .key == "LOW"    then 3
                else 4 end
            ) | .[] | "  \(.key): \(.value)"'

        local total
        total=$(echo "$scan_json" | jq '[.imageScanFindings.findings[]? | .severity] | length')
        echo "  ─────────────────"
        echo "  Total findings: ${total}"

        # Show top 10 findings by severity
        echo ""
        echo "  Top findings:"
        echo "$scan_json" | jq -r '
            .imageScanFindings.findings // [] |
            sort_by(
                if .severity == "CRITICAL" then 0
                elif .severity == "HIGH"   then 1
                elif .severity == "MEDIUM" then 2
                elif .severity == "LOW"    then 3
                else 4 end
            ) | .[0:10][] |
            "  [\(.severity)] \(.name) — \(.description // "no description" | .[0:80])"'
    fi
}

# ─── Dispatch ─────────────────────────────────────────────────────────────────

case "$CMD" in
    setup-builder) cmd_setup_builder ;;
    build)         cmd_build         ;;
    build-push)    cmd_build_push    ;;
    push)          cmd_push          ;;
    pull)          cmd_pull          ;;
    list)          cmd_list          ;;
    inspect)       cmd_inspect       ;;
    scan)          cmd_scan          ;;
    login)         cmd_login         ;;
esac
