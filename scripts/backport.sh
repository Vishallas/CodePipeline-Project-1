#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# scripts/backport.sh — Cherry-pick commits across pg* branches
#
# Usage:
#   backport.sh --from pg16 --to pg15 pg14 --commit SHA [--packages-dir DIR] [--dry-run]
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

# ─── Args ─────────────────────────────────────────────────────────────────────

FROM_BRANCH=""
TO_BRANCHES=()
COMMIT_SHA=""
PACKAGES_DIR=""
DRY_RUN=0

while [[ $# -gt 0 ]]; do
    case $1 in
        --from)         FROM_BRANCH="$2"; shift 2 ;;
        --to)
            shift
            while [[ $# -gt 0 && ! "$1" =~ ^-- ]]; do
                TO_BRANCHES+=("$1"); shift
            done ;;
        --commit)       COMMIT_SHA="$2"; shift 2 ;;
        --packages-dir) PACKAGES_DIR="$2"; shift 2 ;;
        --dry-run)      DRY_RUN=1; shift ;;
        *) log_error "Unknown argument: $1"; exit 1 ;;
    esac
done

if [[ -z "$FROM_BRANCH" || ${#TO_BRANCHES[@]} -eq 0 || -z "$COMMIT_SHA" ]]; then
    log_error "--from, --to, and --commit are required"
    exit 1
fi

if [[ -z "$PACKAGES_DIR" ]]; then
    log_error "--packages-dir is required"
    exit 1
fi

PACKAGES_DIR="$(cd "$PACKAGES_DIR" && pwd)"

# ─── Backport ─────────────────────────────────────────────────────────────────

ORIGINAL_BRANCH=$(cd "$PACKAGES_DIR" && git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")

cleanup() {
    if [[ -n "$ORIGINAL_BRANCH" ]]; then
        (cd "$PACKAGES_DIR" && git checkout "$ORIGINAL_BRANCH" 2>/dev/null) || true
    fi
}
trap cleanup EXIT

FAILED_BRANCHES=()

for target in "${TO_BRANCHES[@]}"; do
    log_step "Backporting ${COMMIT_SHA} → ${target}"

    (
        cd "$PACKAGES_DIR"
        git checkout "$target" || {
            log_error "Branch not found: $target"
            exit 1
        }

        if [[ $DRY_RUN -eq 1 ]]; then
            log_info "[dry-run] would cherry-pick ${COMMIT_SHA} onto ${target}"
            git cherry-pick --no-commit "$COMMIT_SHA" 2>&1 || {
                log_error "CONFLICT on ${target} — aborting dry-run"
                git cherry-pick --abort 2>/dev/null || true
                exit 1
            }
            git checkout . 2>/dev/null || true
        else
            if ! git cherry-pick "$COMMIT_SHA"; then
                log_error "Cherry-pick conflict on ${target}"
                log_error "Resolve conflicts, then:"
                log_error "  cd ${PACKAGES_DIR}"
                log_error "  git cherry-pick --continue"
                log_error "Or abort: git cherry-pick --abort"
                git cherry-pick --abort 2>/dev/null || true
                exit 1
            fi
            log_success "Cherry-picked ${COMMIT_SHA} onto ${target}"
        fi
    ) || FAILED_BRANCHES+=("$target")
done

if [[ ${#FAILED_BRANCHES[@]} -gt 0 ]]; then
    log_error "Failed backports: ${FAILED_BRANCHES[*]}"
    exit 1
fi

log_success "Backport complete: ${COMMIT_SHA} applied to ${TO_BRANCHES[*]}"
