#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# scripts/manage-build-images.sh — Build, push, pull, and inspect ECR images
#
# Usage:
#   manage-build-images.sh <command> [--target TAG] [--pg-versions "14 15 16 17"]
#
# Commands:
#   build   [--target TAG]  Build one or all images locally
#   push    [--target TAG]  Push one or all images to ECR
#   pull    [--target TAG]  Pull one or all images from ECR
#   list                    List all images + ECR existence status
#   scan    [--target TAG]  Trigger ECR vulnerability scan
#   login                   ECR docker login only
#
# Options:
#   --target TAG        One image tag, e.g. ubuntu-22.04-amd64
#                       Omit to run command on ALL images
#   --pg-versions LIST  Space-separated PG majors to embed (default: "14 15 16 17")
#   --account ID        AWS account ID (or set ECR_ACCOUNT_ID env)
#   --region  REGION    AWS region    (or set ECR_REGION env)
#   --repo    REPO      ECR repo name (default: mydbops/pg-build)
#   --dry-run           Print commands without executing
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
ECR_REPO="${ECR_REPO:-$(yaml_get "$REPOS_YML" 'ecr.repository' 2>/dev/null || echo 'mydbops/pg-build')}"
PG_VERSIONS="${PG_VERSIONS:-14 15 16 17}"

CMD=""
TARGET=""
DRY_RUN=0

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
        build|push|pull|list|scan|login) CMD="$1"; shift ;;
        --target)      TARGET="$2";      shift 2 ;;
        --pg-versions) PG_VERSIONS="$2"; shift 2 ;;
        --account)     ECR_ACCOUNT_ID="$2"; shift 2 ;;
        --region)      ECR_REGION="$2";  shift 2 ;;
        --repo)        ECR_REPO="$2";    shift 2 ;;
        --dry-run)     DRY_RUN=1;        shift ;;
        *) log_error "Unknown argument: $1"; exit 1 ;;
    esac
done

if [[ -z "$CMD" ]]; then
    echo "Usage: manage-build-images.sh <build|push|pull|list|scan|login> [options]"
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

cmd_login() {
    require_ecr_account
    log_step "ECR login: $(ecr_uri)"
    run_cmd aws ecr get-login-password --region "$ECR_REGION" \
        | docker login --username AWS --password-stdin "$(ecr_uri)"
    log_success "ECR login complete"
}

cmd_build() {
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

        log_build "Building: ${tag}  [platform=${platform}]"
        run_cmd docker buildx build \
            --platform "$platform" \
            "${build_arg_flags[@]}" \
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

    printf "%-30s %-14s %-12s %s\n" "TAG" "PLATFORM" "LOCAL" "ECR"
    printf "%-30s %-14s %-12s %s\n" "---" "--------" "-----" "---"

    for tag in "${ALL_TAGS[@]}"; do
        local platform="${IMAGE_PLATFORM[$tag]}"
        local ecr_tag
        ecr_tag=$(full_image "$tag")

        local local_status="absent"
        docker image inspect "${ECR_REPO}:${tag}" &>/dev/null && local_status="present"

        local ecr_status="absent"
        if aws ecr describe-images \
                --repository-name "$ECR_REPO" \
                --region "$ECR_REGION" \
                --image-ids imageTag="$tag" \
                &>/dev/null 2>&1; then
            ecr_status="present"
        fi

        printf "%-30s %-14s %-12s %s\n" "$tag" "$platform" "$local_status" "$ecr_status"
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

# ─── Dispatch ─────────────────────────────────────────────────────────────────

case "$CMD" in
    build) cmd_build ;;
    push)  cmd_push  ;;
    pull)  cmd_pull  ;;
    list)  cmd_list  ;;
    scan)  cmd_scan  ;;
    login) cmd_login ;;
esac
