#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# scripts/lib/pulp.sh — Pulp repository integration helpers
#
# Every function is a no-op if PULP_URL is empty or unset.
# Requires: common.sh sourced first
# ─────────────────────────────────────────────────────────────────────────────

[[ -n "${_MYDBOPS_PULP_LOADED:-}" ]] && return 0
_MYDBOPS_PULP_LOADED=1

# pulp_check_configured
# Returns 0 if Pulp is configured (PULP_URL set and non-empty), 1 otherwise.
pulp_check_configured() {
    if [[ -z "${PULP_URL:-}" ]]; then
        return 1
    fi
    return 0
}

# pulp_get_password
# Fetches Pulp password from Secrets Manager into PULP_PASSWORD.
pulp_get_password() {
    pulp_check_configured || return 0
    local secret_name="${PULP_PASSWORD_SECRET:-pg-platform/cicd/pulp-password}"
    PULP_PASSWORD=$(secrets_manager_get "$secret_name") || {
        log_warn "Could not fetch Pulp password from Secrets Manager"
        return 0
    }
    export PULP_PASSWORD
}

# pulp_upload_rpm <rpm_file> <repo_name>
# Uploads an RPM to a Pulp repository. Non-blocking.
pulp_upload_rpm() {
    local rpm_file="$1"
    local repo_name="$2"
    pulp_check_configured || return 0

    log_info "Pulp: uploading RPM $(basename "$rpm_file") to ${repo_name}"
    pulp rpm content upload \
        --repository "$repo_name" \
        --file "$rpm_file" \
        2>&1 || log_warn "Pulp RPM upload failed for $(basename "$rpm_file") — non-fatal"
}

# pulp_upload_deb <deb_file> <repo_name>
# Uploads a DEB to a Pulp repository. Non-blocking.
pulp_upload_deb() {
    local deb_file="$1"
    local repo_name="$2"
    pulp_check_configured || return 0

    log_info "Pulp: uploading DEB $(basename "$deb_file") to ${repo_name}"
    pulp deb content upload \
        --repository "$repo_name" \
        --file "$deb_file" \
        2>&1 || log_warn "Pulp DEB upload failed for $(basename "$deb_file") — non-fatal"
}

# pulp_publish_rpm <repo_name>
# Creates a new publication for the RPM repository. Non-blocking.
pulp_publish_rpm() {
    local repo_name="$1"
    pulp_check_configured || return 0

    log_info "Pulp: publishing RPM repo ${repo_name}"
    pulp rpm publication create \
        --repository "$repo_name" \
        2>&1 || log_warn "Pulp RPM publication failed for ${repo_name} — non-fatal"
}

# pulp_publish_deb <repo_name> <dist> <component> <arch>
# Creates a new APT publication. Non-blocking.
pulp_publish_deb() {
    local repo_name="$1"
    local dist="$2"
    local component="$3"
    local arch="$4"
    pulp_check_configured || return 0

    log_info "Pulp: publishing DEB repo ${repo_name} (${dist})"
    pulp deb publication create \
        --repository "$repo_name" \
        2>&1 || log_warn "Pulp DEB publication failed for ${repo_name} — non-fatal"
}

# pulp_sync_after_upload <pkg> <version> <type: rpm|deb> <repo>
# Orchestrates upload + publish. Wrapped in || log_warn so it never fails the pipeline.
pulp_sync_after_upload() {
    local pkg="$1"
    local version="$2"
    local type="$3"
    local repo="$4"

    pulp_check_configured || return 0

    {
        if [[ "$type" == "rpm" ]]; then
            pulp_publish_rpm "$repo"
        else
            pulp_publish_deb "$repo" "" "main" ""
        fi
        log_success "Pulp sync complete for ${pkg} ${version} (${type})"
    } || log_warn "Pulp sync failed for ${pkg} ${version} — pipeline continues"
}
