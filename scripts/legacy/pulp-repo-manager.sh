#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# pulp-repo-manager.sh — Pulp RPM repository management for PostgreSQL
# ─────────────────────────────────────────────────────────────────────────────
#
# Manages the full lifecycle of PostgreSQL RPM repositories in Pulp:
#   - Create repositories for each PG version × distro × arch
#   - Upload packages from build output
#   - Publish repository metadata (signed)
#   - Create/update distributions for content serving
#   - Sync from upstream remotes
#   - Repository maintenance (retain, cleanup, snapshot)
#
# Usage:
#   ./scripts/pulp-repo-manager.sh <command> [options]
#
# Commands:
#   init              Create all repositories, publications, and distributions
#   upload            Upload built packages to Pulp repositories
#   publish           Publish repository metadata (sign + generate repodata)
#   distribute        Create/update distributions (serve content)
#   sync              Sync from upstream remote (if configured)
#   status            Show repository status and package counts
#   snapshot          Create named snapshots of current repo state
#   retain            Apply retention policy (remove old versions)
#   cleanup           Remove orphaned content
#   repo-file         Generate .repo file for clients
#   full-publish      Upload + publish + distribute (complete pipeline)
#
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
PIPELINE_CONF="${REPO_ROOT}/pipeline.conf"
PULP_CONF="${REPO_ROOT}/configs/pulp.conf"

# ─── Colors & Logging ────────────────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

log_info()    { echo -e "${BLUE}[INFO]${NC}    $*"; }
log_success() { echo -e "${GREEN}[OK]${NC}      $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}    $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC}   $*"; }
log_step()    { echo -e "${CYAN}[STEP]${NC}    $*"; }

# ─── Load Configuration ─────────────────────────────────────────────────────

load_config() {
    if [ ! -f "$PIPELINE_CONF" ]; then
        log_error "Pipeline configuration not found: ${PIPELINE_CONF}"
        exit 1
    fi
    source "$PIPELINE_CONF"

    if [ ! -f "$PULP_CONF" ]; then
        log_error "Pulp configuration not found: ${PULP_CONF}"
        log_error "Copy and edit: cp configs/pulp.conf.example configs/pulp.conf"
        exit 1
    fi
    source "$PULP_CONF"

    # Validate required settings
    if [ -z "${PULP_BASE_URL:-}" ] || [ "$PULP_BASE_URL" = "https://pulp.example.com" ]; then
        log_error "PULP_BASE_URL not configured in configs/pulp.conf"
        exit 1
    fi
    if [ -z "${PULP_PASSWORD:-}" ] && [ -z "${PULP_CLIENT_CERT:-}" ]; then
        log_error "No Pulp authentication configured (set PULP_PASSWORD or PULP_CLIENT_CERT)"
        exit 1
    fi
}

# ─── Parse pipeline.conf helpers ─────────────────────────────────────────────

parse_pg_version() {
    IFS=':' read -r _PG_MAJOR _PG_FULL _PG_RELEASE _PG_ENABLED <<< "$1"
}

parse_build_target() {
    IFS=':' read -r _BT_DISTRO _BT_IMAGE _BT_ENABLED <<< "$1"
}

# Map distro ID to Pulp-friendly name (lowercase, no hyphens)
distro_to_pulp_name() {
    echo "$1" | tr '[:upper:]-' '[:lower:]_'
}

# ─── Pulp API ────────────────────────────────────────────────────────────────

pulp_api() {
    local method="$1"
    local endpoint="$2"
    shift 2

    local auth_args=()
    if [ -n "${PULP_CLIENT_CERT:-}" ] && [ -n "${PULP_CLIENT_KEY:-}" ]; then
        auth_args+=(--cert "$PULP_CLIENT_CERT" --key "$PULP_CLIENT_KEY")
    elif [ -n "${PULP_USERNAME:-}" ] && [ -n "${PULP_PASSWORD:-}" ]; then
        auth_args+=(-u "${PULP_USERNAME}:${PULP_PASSWORD}")
    fi

    local ca_args=()
    if [ -n "${PULP_CA_CERT:-}" ]; then
        ca_args+=(--cacert "$PULP_CA_CERT")
    fi

    local response http_code
    response=$(curl -s -w "\n%{http_code}" -X "$method" \
        "${auth_args[@]}" \
        "${ca_args[@]}" \
        --max-time "${PULP_API_TIMEOUT:-30}" \
        -H "Content-Type: application/json" \
        "$@" \
        "${PULP_BASE_URL}${endpoint}" 2>&1)

    http_code=$(echo "$response" | tail -1)
    local body
    body=$(echo "$response" | sed '$d')

    # Return body and set global for status checking
    _PULP_HTTP_CODE="$http_code"
    echo "$body"
}

# Upload a file (multipart form)
pulp_upload() {
    local endpoint="$1"
    local file_path="$2"
    shift 2

    local auth_args=()
    if [ -n "${PULP_CLIENT_CERT:-}" ] && [ -n "${PULP_CLIENT_KEY:-}" ]; then
        auth_args+=(--cert "$PULP_CLIENT_CERT" --key "$PULP_CLIENT_KEY")
    elif [ -n "${PULP_USERNAME:-}" ] && [ -n "${PULP_PASSWORD:-}" ]; then
        auth_args+=(-u "${PULP_USERNAME}:${PULP_PASSWORD}")
    fi

    local ca_args=()
    if [ -n "${PULP_CA_CERT:-}" ]; then
        ca_args+=(--cacert "$PULP_CA_CERT")
    fi

    curl -s -X POST \
        "${auth_args[@]}" \
        "${ca_args[@]}" \
        --max-time 300 \
        -F "file=@${file_path}" \
        "$@" \
        "${PULP_BASE_URL}${endpoint}"
}

# Wait for a Pulp task to complete
wait_for_task() {
    local task_href="$1"
    local max_wait="${2:-300}"
    local interval=5
    local elapsed=0

    while [ "$elapsed" -lt "$max_wait" ]; do
        local task_status
        task_status=$(pulp_api GET "$task_href" | python3 -c "
import sys, json
task = json.load(sys.stdin)
print(task.get('state', 'unknown'))
" 2>/dev/null)

        case "$task_status" in
            completed)
                return 0
                ;;
            failed|canceled|cancelled)
                log_error "Task failed: ${task_href}"
                pulp_api GET "$task_href" | python3 -c "
import sys, json
task = json.load(sys.stdin)
for err in task.get('error', {}).get('descriptions', [task.get('error', {}).get('description', 'unknown')]):
    print(f'  Error: {err}')
" 2>/dev/null || true
                return 1
                ;;
            running|waiting)
                sleep "$interval"
                elapsed=$((elapsed + interval))
                ;;
            *)
                sleep "$interval"
                elapsed=$((elapsed + interval))
                ;;
        esac
    done

    log_error "Task timed out after ${max_wait}s: ${task_href}"
    return 1
}

# ─── Repository Name Helpers ─────────────────────────────────────────────────

# Generate repo name: postgresql-17-el9-x86_64
repo_name() {
    local pg_major="$1" distro="$2" arch="$3"
    local pulp_distro
    pulp_distro=$(distro_to_pulp_name "$distro")
    echo "${PULP_REPO_PREFIX}-${pg_major}-${pulp_distro}-${arch}"
}

# Generate distribution base path: postgresql/17/el9/x86_64
dist_base_path() {
    local pg_major="$1" distro="$2" arch="$3"
    local pulp_distro
    pulp_distro=$(distro_to_pulp_name "$distro")
    echo "${PULP_DIST_BASE_PATH}/${pg_major}/${pulp_distro}/${arch}"
}

# ─── Commands ────────────────────────────────────────────────────────────────

cmd_init() {
    load_config

    echo ""
    echo "═══════════════════════════════════════════════════════════════════"
    echo "  Initializing Pulp Repositories"
    echo "═══════════════════════════════════════════════════════════════════"
    echo ""

    local created=0
    local skipped=0

    for v_entry in "${PG_VERSIONS[@]}"; do
        parse_pg_version "$v_entry"
        [ "$_PG_ENABLED" != "1" ] && continue
        local pg_major="$_PG_MAJOR"

        for d_entry in "${BUILD_TARGETS[@]}"; do
            parse_build_target "$d_entry"
            [ "$_BT_ENABLED" != "1" ] && continue
            local distro="$_BT_DISTRO"

            for arch in "${PULP_ARCHITECTURES[@]}"; do
                local name
                name=$(repo_name "$pg_major" "$distro" "$arch")
                local base_path
                base_path=$(dist_base_path "$pg_major" "$distro" "$arch")

                # Check if repository already exists
                local existing
                existing=$(pulp_api GET "/pulp/api/v3/repositories/rpm/rpm/?name=${name}" | \
                    python3 -c "import sys,json; print(json.load(sys.stdin).get('count',0))" 2>/dev/null || echo "0")

                if [ "$existing" != "0" ]; then
                    log_info "Repository exists: ${name}"
                    skipped=$((skipped + 1))
                    continue
                fi

                # Create repository
                log_step "Creating repository: ${name}"
                local repo_data="{
                    \"name\": \"${name}\",
                    \"retain_package_versions\": ${PULP_RETAIN_PACKAGE_VERSIONS:-3},
                    \"autopublish\": $([ "${PULP_AUTO_PUBLISH:-1}" = "1" ] && echo "true" || echo "false")
                }"

                local repo_response
                repo_response=$(pulp_api POST "/pulp/api/v3/repositories/rpm/rpm/" -d "$repo_data")
                local repo_href
                repo_href=$(echo "$repo_response" | python3 -c "import sys,json; print(json.load(sys.stdin).get('pulp_href',''))" 2>/dev/null)

                if [ -z "$repo_href" ]; then
                    log_error "Failed to create repository: ${name}"
                    echo "$repo_response" | python3 -m json.tool 2>/dev/null || echo "$repo_response"
                    continue
                fi

                log_success "Created repository: ${name} (${repo_href})"

                # Create publication if not auto-publish
                if [ "${PULP_AUTO_PUBLISH:-1}" != "1" ]; then
                    _create_publication "$repo_href" "$name"
                fi

                # Create distribution
                _create_distribution "$name" "$base_path" "$repo_href"

                created=$((created + 1))
            done
        done
    done

    echo ""
    log_success "Init complete: ${created} created, ${skipped} already existed"
    echo ""
}

_create_publication() {
    local repo_href="$1"
    local name="$2"

    log_step "Creating publication for: ${name}"

    local pub_data="{\"repository\": \"${repo_href}\""

    # Add signing service if configured
    if [ -n "${PULP_SIGNING_SERVICE:-}" ] && [ "${PULP_SIGN_METADATA:-0}" = "1" ]; then
        local signing_href
        signing_href=$(_get_signing_service_href)
        if [ -n "$signing_href" ]; then
            pub_data="${pub_data}, \"metadata_signing_service\": \"${signing_href}\""
        fi
    fi

    # Add GPG key for gpgcheck
    if [ -n "${PULP_GPG_PUBLIC_KEY:-}" ] && [ -f "${PULP_GPG_PUBLIC_KEY}" ]; then
        local gpg_key_content
        gpg_key_content=$(cat "$PULP_GPG_PUBLIC_KEY")
        pub_data="${pub_data}, \"gpgcheck\": $([ "${PULP_GPGCHECK:-1}" = "1" ] && echo "1" || echo "0")"
    fi

    pub_data="${pub_data}}"

    local pub_response
    pub_response=$(pulp_api POST "/pulp/api/v3/publications/rpm/rpm/" -d "$pub_data")

    local task_href
    task_href=$(echo "$pub_response" | python3 -c "import sys,json; print(json.load(sys.stdin).get('task',''))" 2>/dev/null)

    if [ -n "$task_href" ]; then
        wait_for_task "$task_href" && log_success "Publication created for: ${name}"
    fi
}

_create_distribution() {
    local name="$1"
    local base_path="$2"
    local repo_href="$3"

    log_step "Creating distribution: ${base_path}"

    local dist_data="{
        \"name\": \"${name}\",
        \"base_path\": \"${base_path}\",
        \"repository\": \"${repo_href}\"
    }"

    # Add content guard if configured
    if [ -n "${PULP_CONTENT_GUARD:-}" ]; then
        dist_data=$(echo "$dist_data" | python3 -c "
import sys, json
d = json.load(sys.stdin)
d['content_guard'] = '${PULP_CONTENT_GUARD}'
print(json.dumps(d))
" 2>/dev/null)
    fi

    local dist_response
    dist_response=$(pulp_api POST "/pulp/api/v3/distributions/rpm/rpm/" -d "$dist_data")

    local task_href
    task_href=$(echo "$dist_response" | python3 -c "import sys,json; print(json.load(sys.stdin).get('task',''))" 2>/dev/null)

    if [ -n "$task_href" ]; then
        wait_for_task "$task_href" && log_success "Distribution created: ${base_path}"
    fi
}

_get_signing_service_href() {
    local response
    response=$(pulp_api GET "/pulp/api/v3/signing-services/?name=${PULP_SIGNING_SERVICE}")
    echo "$response" | python3 -c "
import sys, json
data = json.load(sys.stdin)
if data.get('count', 0) > 0:
    print(data['results'][0]['pulp_href'])
" 2>/dev/null
}

cmd_upload() {
    load_config

    local target_pg="${1:-}"
    local target_distro="${2:-}"

    echo ""
    echo "═══════════════════════════════════════════════════════════════════"
    echo "  Uploading Packages to Pulp"
    echo "═══════════════════════════════════════════════════════════════════"
    echo ""

    # Check GPG key expiry before upload
    if [ -f "${SCRIPT_DIR}/gpg-key-manager.sh" ] && [ "${SIGN_PACKAGES:-0}" = "1" ]; then
        log_step "Checking GPG key expiry..."
        if ! "${SCRIPT_DIR}/gpg-key-manager.sh" check-expiry 2>/dev/null; then
            log_warn "GPG key expiry warning — packages may not be properly signed"
        fi
    fi

    local uploaded=0
    local failed=0

    for v_entry in "${PG_VERSIONS[@]}"; do
        parse_pg_version "$v_entry"
        [ "$_PG_ENABLED" != "1" ] && continue
        local pg_major="$_PG_MAJOR"

        # Filter by specific PG version if requested
        if [ -n "$target_pg" ] && [ "$pg_major" != "$target_pg" ]; then
            continue
        fi

        for d_entry in "${BUILD_TARGETS[@]}"; do
            parse_build_target "$d_entry"
            [ "$_BT_ENABLED" != "1" ] && continue
            local distro="$_BT_DISTRO"

            # Filter by specific distro if requested
            if [ -n "$target_distro" ] && [ "$distro" != "$target_distro" ]; then
                continue
            fi

            # Find built RPMs in segregated output
            local build_dir="${REPO_ROOT}/${OUTPUT_DIR}/builds/docker/${distro}/postgresql-${pg_major}/RPMS"
            if [ ! -d "$build_dir" ]; then
                # Try legacy output path
                build_dir="${REPO_ROOT}/${OUTPUT_DIR}/${distro}/postgresql-${pg_major}/RPMS"
            fi

            if [ ! -d "$build_dir" ]; then
                log_warn "No build output for PG${pg_major} × ${distro}"
                continue
            fi

            local rpm_files
            rpm_files=$(find "$build_dir" -name "*.rpm" -not -name "*.src.rpm" 2>/dev/null)

            if [ -z "$rpm_files" ]; then
                log_warn "No RPMs found in: ${build_dir}"
                continue
            fi

            # Upload each RPM to the correct repository
            while IFS= read -r rpm_file; do
                [ -z "$rpm_file" ] && continue

                # Determine architecture from RPM
                local rpm_arch
                rpm_arch=$(rpm -qp --queryformat '%{ARCH}' "$rpm_file" 2>/dev/null || echo "x86_64")

                # Map noarch to all configured architectures
                local target_archs=("$rpm_arch")
                if [ "$rpm_arch" = "noarch" ]; then
                    target_archs=("${PULP_ARCHITECTURES[@]}")
                fi

                for arch in "${target_archs[@]}"; do
                    local name
                    name=$(repo_name "$pg_major" "$distro" "$arch")
                    local rpm_basename
                    rpm_basename=$(basename "$rpm_file")

                    log_info "Uploading: ${rpm_basename} -> ${name}"

                    # Step 1: Create artifact via upload
                    local artifact_response
                    artifact_response=$(pulp_upload "/pulp/api/v3/artifacts/" "$rpm_file")
                    local artifact_href
                    artifact_href=$(echo "$artifact_response" | python3 -c "import sys,json; print(json.load(sys.stdin).get('pulp_href',''))" 2>/dev/null)

                    if [ -z "$artifact_href" ]; then
                        # Artifact may already exist (duplicate upload)
                        artifact_href=$(echo "$artifact_response" | python3 -c "
import sys, json
data = json.load(sys.stdin)
# Check for 'already exists' with existing href
for key in ('non_field_errors', 'detail'):
    if key in data:
        break
# Try to extract sha256 and look up
" 2>/dev/null || echo "")

                        if [ -z "$artifact_href" ]; then
                            log_warn "  Artifact may already exist, trying content creation directly"
                        fi
                    fi

                    # Step 2: Create RPM content from artifact
                    local content_response
                    if [ -n "$artifact_href" ]; then
                        content_response=$(pulp_api POST "/pulp/api/v3/content/rpm/packages/" \
                            -d "{\"artifact\": \"${artifact_href}\", \"repository\": \"/pulp/api/v3/repositories/rpm/rpm/?name=${name}\"}")
                    else
                        # Use single-shot upload API
                        content_response=$(pulp_upload "/pulp/api/v3/content/rpm/packages/" "$rpm_file" \
                            -F "repository=$(pulp_api GET "/pulp/api/v3/repositories/rpm/rpm/?name=${name}" | \
                                python3 -c "import sys,json; print(json.load(sys.stdin)['results'][0]['pulp_href'])" 2>/dev/null)")
                    fi

                    local task_href
                    task_href=$(echo "$content_response" | python3 -c "import sys,json; print(json.load(sys.stdin).get('task',''))" 2>/dev/null || echo "")

                    if [ -n "$task_href" ]; then
                        if wait_for_task "$task_href" 120; then
                            log_success "  Uploaded: ${rpm_basename} -> ${name}"
                            uploaded=$((uploaded + 1))
                        else
                            log_error "  Failed: ${rpm_basename}"
                            failed=$((failed + 1))
                        fi
                    else
                        # May have been added directly (synchronous)
                        local content_href
                        content_href=$(echo "$content_response" | python3 -c "import sys,json; print(json.load(sys.stdin).get('pulp_href',''))" 2>/dev/null || echo "")
                        if [ -n "$content_href" ]; then
                            log_success "  Uploaded: ${rpm_basename} -> ${name}"
                            uploaded=$((uploaded + 1))
                        else
                            log_error "  Failed: ${rpm_basename}"
                            failed=$((failed + 1))
                        fi
                    fi
                done
            done <<< "$rpm_files"
        done
    done

    echo ""
    log_success "Upload complete: ${uploaded} uploaded, ${failed} failed"
    echo ""

    [ "$failed" -gt 0 ] && return 1 || return 0
}

cmd_publish() {
    load_config

    echo ""
    echo "═══════════════════════════════════════════════════════════════════"
    echo "  Publishing Repository Metadata"
    echo "═══════════════════════════════════════════════════════════════════"
    echo ""

    # Check GPG key expiry before signing metadata
    if [ "${PULP_SIGN_METADATA:-0}" = "1" ]; then
        log_step "Verifying signing key..."
        if [ -f "${SCRIPT_DIR}/gpg-key-manager.sh" ]; then
            if ! "${SCRIPT_DIR}/gpg-key-manager.sh" check-expiry 2>/dev/null; then
                log_error "GPG key expiry check failed — refusing to publish with expiring key"
                log_error "Run: ./scripts/gpg-key-manager.sh rotate"
                return 1
            fi
        fi
    fi

    local signing_href=""
    if [ -n "${PULP_SIGNING_SERVICE:-}" ] && [ "${PULP_SIGN_METADATA:-0}" = "1" ]; then
        signing_href=$(_get_signing_service_href)
        if [ -n "$signing_href" ]; then
            log_info "Using signing service: ${PULP_SIGNING_SERVICE}"
        else
            log_warn "Signing service '${PULP_SIGNING_SERVICE}' not found — publishing unsigned"
        fi
    fi

    local published=0

    for v_entry in "${PG_VERSIONS[@]}"; do
        parse_pg_version "$v_entry"
        [ "$_PG_ENABLED" != "1" ] && continue

        for d_entry in "${BUILD_TARGETS[@]}"; do
            parse_build_target "$d_entry"
            [ "$_BT_ENABLED" != "1" ] && continue

            for arch in "${PULP_ARCHITECTURES[@]}"; do
                local name
                name=$(repo_name "$_PG_MAJOR" "$_BT_DISTRO" "$arch")

                # Get repository href
                local repo_href
                repo_href=$(pulp_api GET "/pulp/api/v3/repositories/rpm/rpm/?name=${name}" | \
                    python3 -c "import sys,json; r=json.load(sys.stdin); print(r['results'][0]['pulp_href'] if r.get('count',0)>0 else '')" 2>/dev/null)

                if [ -z "$repo_href" ]; then
                    log_warn "Repository not found: ${name}"
                    continue
                fi

                log_step "Publishing: ${name}"

                local pub_data="{\"repository\": \"${repo_href}\""
                if [ -n "$signing_href" ]; then
                    pub_data="${pub_data}, \"metadata_signing_service\": \"${signing_href}\""
                fi
                pub_data="${pub_data}}"

                local response
                response=$(pulp_api POST "/pulp/api/v3/publications/rpm/rpm/" -d "$pub_data")

                local task_href
                task_href=$(echo "$response" | python3 -c "import sys,json; print(json.load(sys.stdin).get('task',''))" 2>/dev/null || echo "")

                if [ -n "$task_href" ]; then
                    if wait_for_task "$task_href"; then
                        log_success "Published: ${name}"
                        published=$((published + 1))
                    else
                        log_error "Publish failed: ${name}"
                    fi
                fi
            done
        done
    done

    echo ""
    log_success "Publish complete: ${published} repositories published"
    echo ""
}

cmd_distribute() {
    load_config

    echo ""
    log_step "Updating distributions..."
    echo ""

    for v_entry in "${PG_VERSIONS[@]}"; do
        parse_pg_version "$v_entry"
        [ "$_PG_ENABLED" != "1" ] && continue

        for d_entry in "${BUILD_TARGETS[@]}"; do
            parse_build_target "$d_entry"
            [ "$_BT_ENABLED" != "1" ] && continue

            for arch in "${PULP_ARCHITECTURES[@]}"; do
                local name
                name=$(repo_name "$_PG_MAJOR" "$_BT_DISTRO" "$arch")
                local base_path
                base_path=$(dist_base_path "$_PG_MAJOR" "$_BT_DISTRO" "$arch")

                # Check if distribution exists
                local existing
                existing=$(pulp_api GET "/pulp/api/v3/distributions/rpm/rpm/?name=${name}" | \
                    python3 -c "import sys,json; print(json.load(sys.stdin).get('count',0))" 2>/dev/null || echo "0")

                if [ "$existing" = "0" ]; then
                    # Get repo href for new distribution
                    local repo_href
                    repo_href=$(pulp_api GET "/pulp/api/v3/repositories/rpm/rpm/?name=${name}" | \
                        python3 -c "import sys,json; r=json.load(sys.stdin); print(r['results'][0]['pulp_href'] if r.get('count',0)>0 else '')" 2>/dev/null)

                    if [ -n "$repo_href" ]; then
                        _create_distribution "$name" "$base_path" "$repo_href"
                    else
                        log_warn "No repository for distribution: ${name}"
                    fi
                else
                    log_info "Distribution exists: ${base_path}"
                fi
            done
        done
    done

    echo ""
    log_success "Distributions updated"
    echo ""
}

cmd_status() {
    load_config

    echo ""
    echo "═══════════════════════════════════════════════════════════════════"
    echo "  Pulp Repository Status"
    echo "═══════════════════════════════════════════════════════════════════"
    echo ""

    echo "  Server:     ${PULP_BASE_URL}"
    echo "  Content:    ${PULP_CONTENT_URL:-N/A}"
    echo "  Signing:    $([ "${PULP_SIGN_METADATA:-0}" = "1" ] && echo "enabled (${PULP_SIGNING_SERVICE:-N/A})" || echo "disabled")"
    echo "  Retention:  ${PULP_RETAIN_PACKAGE_VERSIONS:-3} versions"
    echo ""

    printf "  %-40s %-10s %-12s %-10s\n" "Repository" "Packages" "Last Publish" "Status"
    echo "  ─────────────────────────────────────────────────────────────────────────────────"

    for v_entry in "${PG_VERSIONS[@]}"; do
        parse_pg_version "$v_entry"
        [ "$_PG_ENABLED" != "1" ] && continue

        for d_entry in "${BUILD_TARGETS[@]}"; do
            parse_build_target "$d_entry"
            [ "$_BT_ENABLED" != "1" ] && continue

            for arch in "${PULP_ARCHITECTURES[@]}"; do
                local name
                name=$(repo_name "$_PG_MAJOR" "$_BT_DISTRO" "$arch")

                local repo_info
                repo_info=$(pulp_api GET "/pulp/api/v3/repositories/rpm/rpm/?name=${name}" 2>/dev/null)

                local count pkg_count last_publish status_str
                count=$(echo "$repo_info" | python3 -c "import sys,json; print(json.load(sys.stdin).get('count',0))" 2>/dev/null || echo "0")

                if [ "$count" = "0" ]; then
                    printf "  %-40s %-10s %-12s " "$name" "-" "-"
                    echo -e "${DIM}not created${NC}"
                    continue
                fi

                # Get package count from latest version
                pkg_count=$(echo "$repo_info" | python3 -c "
import sys, json
data = json.load(sys.stdin)
if data['count'] > 0:
    repo = data['results'][0]
    lv = repo.get('latest_version_href', '')
    print(lv)
else:
    print('')
" 2>/dev/null || echo "")

                if [ -n "$pkg_count" ]; then
                    local version_info
                    version_info=$(pulp_api GET "$pkg_count" 2>/dev/null)
                    local num_packages
                    num_packages=$(echo "$version_info" | python3 -c "
import sys, json
data = json.load(sys.stdin)
# Count content summary
cs = data.get('content_summary', {}).get('present', {})
total = sum(v.get('count', 0) for v in cs.values())
print(total)
" 2>/dev/null || echo "?")
                    local pub_time
                    pub_time=$(echo "$version_info" | python3 -c "
import sys, json
data = json.load(sys.stdin)
ts = data.get('pulp_created', 'N/A')
print(ts[:10] if ts != 'N/A' else 'N/A')
" 2>/dev/null || echo "N/A")

                    printf "  %-40s %-10s %-12s " "$name" "$num_packages" "$pub_time"
                    echo -e "${GREEN}active${NC}"
                else
                    printf "  %-40s %-10s %-12s " "$name" "0" "never"
                    echo -e "${YELLOW}empty${NC}"
                fi
            done
        done
    done

    echo ""

    # Show signing service status
    if [ "${PULP_SIGN_METADATA:-0}" = "1" ]; then
        echo "  Signing Service:"
        local signing_info
        signing_info=$(pulp_api GET "/pulp/api/v3/signing-services/?name=${PULP_SIGNING_SERVICE:-}" 2>/dev/null)
        local signing_count
        signing_count=$(echo "$signing_info" | python3 -c "import sys,json; print(json.load(sys.stdin).get('count',0))" 2>/dev/null || echo "0")
        if [ "$signing_count" != "0" ]; then
            echo -e "    ${GREEN}${PULP_SIGNING_SERVICE} — registered${NC}"
        else
            echo -e "    ${RED}${PULP_SIGNING_SERVICE} — NOT FOUND${NC}"
        fi
        echo ""
    fi

    echo "═══════════════════════════════════════════════════════════════════"
    echo ""
}

cmd_snapshot() {
    load_config

    local snapshot_name="${1:-snapshot-$(date +%Y%m%d-%H%M%S)}"

    echo ""
    log_step "Creating snapshots: ${snapshot_name}"
    echo ""

    local created=0

    for v_entry in "${PG_VERSIONS[@]}"; do
        parse_pg_version "$v_entry"
        [ "$_PG_ENABLED" != "1" ] && continue

        for d_entry in "${BUILD_TARGETS[@]}"; do
            parse_build_target "$d_entry"
            [ "$_BT_ENABLED" != "1" ] && continue

            for arch in "${PULP_ARCHITECTURES[@]}"; do
                local name
                name=$(repo_name "$_PG_MAJOR" "$_BT_DISTRO" "$arch")

                local repo_href
                repo_href=$(pulp_api GET "/pulp/api/v3/repositories/rpm/rpm/?name=${name}" | \
                    python3 -c "import sys,json; r=json.load(sys.stdin); print(r['results'][0]['pulp_href'] if r.get('count',0)>0 else '')" 2>/dev/null)

                if [ -z "$repo_href" ]; then
                    continue
                fi

                local version_href
                version_href=$(pulp_api GET "/pulp/api/v3/repositories/rpm/rpm/?name=${name}" | \
                    python3 -c "import sys,json; r=json.load(sys.stdin); print(r['results'][0].get('latest_version_href','') if r.get('count',0)>0 else '')" 2>/dev/null)

                if [ -n "$version_href" ]; then
                    # Create a distribution pointing to this specific version as a snapshot
                    local snap_name="${name}-${snapshot_name}"
                    local snap_path="${PULP_DIST_BASE_PATH}/snapshots/${snapshot_name}/${_PG_MAJOR}/$(distro_to_pulp_name "$_BT_DISTRO")/${arch}"

                    local dist_data="{
                        \"name\": \"${snap_name}\",
                        \"base_path\": \"${snap_path}\",
                        \"repository_version\": \"${version_href}\"
                    }"

                    local response
                    response=$(pulp_api POST "/pulp/api/v3/distributions/rpm/rpm/" -d "$dist_data")
                    local task_href
                    task_href=$(echo "$response" | python3 -c "import sys,json; print(json.load(sys.stdin).get('task',''))" 2>/dev/null || echo "")

                    if [ -n "$task_href" ] && wait_for_task "$task_href"; then
                        log_success "Snapshot: ${snap_name}"
                        created=$((created + 1))
                    fi
                fi
            done
        done
    done

    echo ""
    log_success "Created ${created} snapshots with tag: ${snapshot_name}"
    echo ""
}

cmd_retain() {
    load_config

    local retain="${PULP_RETAIN_PACKAGE_VERSIONS:-3}"

    echo ""
    log_step "Applying retention policy: keep ${retain} latest versions"
    echo ""

    # Retention is handled automatically by Pulp's retain_package_versions
    # setting on the repository. This command ensures it's set correctly.

    for v_entry in "${PG_VERSIONS[@]}"; do
        parse_pg_version "$v_entry"
        [ "$_PG_ENABLED" != "1" ] && continue

        for d_entry in "${BUILD_TARGETS[@]}"; do
            parse_build_target "$d_entry"
            [ "$_BT_ENABLED" != "1" ] && continue

            for arch in "${PULP_ARCHITECTURES[@]}"; do
                local name
                name=$(repo_name "$_PG_MAJOR" "$_BT_DISTRO" "$arch")

                local repo_response
                repo_response=$(pulp_api GET "/pulp/api/v3/repositories/rpm/rpm/?name=${name}")
                local repo_href
                repo_href=$(echo "$repo_response" | python3 -c "import sys,json; r=json.load(sys.stdin); print(r['results'][0]['pulp_href'] if r.get('count',0)>0 else '')" 2>/dev/null)

                if [ -z "$repo_href" ]; then
                    continue
                fi

                # Update retention setting
                pulp_api PATCH "$repo_href" -d "{\"retain_package_versions\": ${retain}}" >/dev/null 2>&1
                log_info "Updated retention for: ${name} (keep ${retain})"
            done
        done
    done

    echo ""
    log_success "Retention policy applied"
    echo ""
}

cmd_cleanup() {
    load_config

    echo ""
    log_step "Cleaning up orphaned content..."
    echo ""

    local response
    response=$(pulp_api POST "/pulp/api/v3/orphans/cleanup/" -d '{"orphan_protection_time": 0}')

    local task_href
    task_href=$(echo "$response" | python3 -c "import sys,json; print(json.load(sys.stdin).get('task',''))" 2>/dev/null || echo "")

    if [ -n "$task_href" ]; then
        log_info "Cleanup task started: ${task_href}"
        if wait_for_task "$task_href" 600; then
            log_success "Orphan cleanup complete"
        else
            log_error "Cleanup task failed or timed out"
        fi
    fi

    echo ""
}

cmd_sync() {
    load_config

    if [ "${PULP_UPSTREAM_SYNC:-0}" != "1" ]; then
        log_error "Upstream sync not enabled. Set PULP_UPSTREAM_SYNC=1 in configs/pulp.conf"
        return 1
    fi

    echo ""
    log_step "Syncing from upstream..."
    echo ""

    log_warn "Upstream sync requires remote configuration in Pulp"
    echo "  See: docs/PULP_SETUP_GUIDE.md for remote configuration"
    echo ""
}

cmd_repo_file() {
    load_config

    local target_distro="${1:-}"
    local target_pg="${2:-}"

    if [ -z "$target_distro" ]; then
        log_error "Usage: pulp-repo-manager.sh repo-file <distro> [pg_major]"
        echo "  Example: pulp-repo-manager.sh repo-file EL-9 17"
        exit 1
    fi

    local content_url="${PULP_CONTENT_URL:-${PULP_BASE_URL}/pulp/content}"
    local gpgcheck="${PULP_GPGCHECK:-1}"
    local gpg_key_url="${content_url}/keys/RPM-GPG-KEY-postgresql"

    echo ""
    echo "# PostgreSQL Packages — $(date +%Y-%m-%d)"
    echo "# Install: curl -o /etc/yum.repos.d/postgresql.repo <this-url>"
    echo ""

    for v_entry in "${PG_VERSIONS[@]}"; do
        parse_pg_version "$v_entry"
        [ "$_PG_ENABLED" != "1" ] && continue
        local pg_major="$_PG_MAJOR"

        if [ -n "$target_pg" ] && [ "$pg_major" != "$target_pg" ]; then
            continue
        fi

        for arch in "${PULP_ARCHITECTURES[@]}"; do
            local base_path
            base_path=$(dist_base_path "$pg_major" "$target_distro" "$arch")

            cat <<EOF
[postgresql-${pg_major}-${arch}]
name=PostgreSQL ${pg_major} for $(distro_to_pulp_name "$target_distro") - ${arch}
baseurl=${content_url}/${base_path}/
enabled=1
gpgcheck=${gpgcheck}
gpgkey=${gpg_key_url}
repo_gpgcheck=${gpgcheck}
sslverify=1

EOF
        done
    done
}

cmd_full_publish() {
    load_config

    echo ""
    echo "═══════════════════════════════════════════════════════════════════"
    echo "  Full Publish Pipeline (Upload → Publish → Distribute)"
    echo "═══════════════════════════════════════════════════════════════════"
    echo ""

    local target_pg="${1:-}"
    local target_distro="${2:-}"

    # Step 1: GPG key preflight
    log_step "Step 1/4: GPG key preflight check..."
    if [ -f "${SCRIPT_DIR}/gpg-key-manager.sh" ] && [ "${SIGN_PACKAGES:-0}" = "1" ]; then
        if ! "${SCRIPT_DIR}/gpg-key-manager.sh" check-expiry 2>/dev/null; then
            log_error "GPG key check failed — aborting publish"
            return 1
        fi
        log_success "GPG key is valid"
    else
        log_info "Package signing disabled — skipping key check"
    fi

    # Step 2: Upload
    log_step "Step 2/4: Uploading packages..."
    cmd_upload "$target_pg" "$target_distro" || {
        log_error "Upload failed — aborting"
        return 1
    }

    # Step 3: Publish (with metadata signing)
    log_step "Step 3/4: Publishing repository metadata..."
    cmd_publish || {
        log_error "Publish failed"
        return 1
    }

    # Step 4: Distribute
    log_step "Step 4/4: Updating distributions..."
    cmd_distribute

    echo ""
    echo "═══════════════════════════════════════════════════════════════════"
    echo "  Full Publish Complete"
    echo "═══════════════════════════════════════════════════════════════════"
    echo ""
    echo "  Content URL: ${PULP_CONTENT_URL:-${PULP_BASE_URL}/pulp/content}/${PULP_DIST_BASE_PATH}/"
    echo ""
    echo "  Generate client repo file:"
    echo "    ./scripts/pulp-repo-manager.sh repo-file EL-9"
    echo ""
}

# ─── Usage ───────────────────────────────────────────────────────────────────

usage() {
    cat <<'EOF'
Pulp Repository Manager — PostgreSQL Packaging

Usage: pulp-repo-manager.sh <command> [options]

Commands:
  init                          Create repositories, publications, distributions
  upload [pg_ver] [distro]      Upload built packages to Pulp
  publish                       Publish repository metadata (with signing)
  distribute                    Create/update distributions for content serving
  sync                          Sync from upstream remote
  status                        Show repository status and package counts
  snapshot [name]               Create named snapshot of current state
  retain                        Apply retention policy (remove old versions)
  cleanup                       Remove orphaned content from Pulp
  repo-file <distro> [pg_ver]   Generate .repo file for client systems
  full-publish [pg] [distro]    Complete pipeline: upload + publish + distribute

Examples:
  # Initial setup
  pulp-repo-manager.sh init

  # After building packages
  pulp-repo-manager.sh full-publish

  # Upload only PG17 for EL-9
  pulp-repo-manager.sh upload 17 EL-9

  # Check repository status
  pulp-repo-manager.sh status

  # Create pre-release snapshot
  pulp-repo-manager.sh snapshot pre-release-17.8

  # Generate client .repo file
  pulp-repo-manager.sh repo-file EL-9 > /tmp/postgresql.repo

Configuration:
  configs/pulp.conf    — Pulp server connection and repository settings
  pipeline.conf        — PG versions and build targets

Documentation:
  docs/PULP_SETUP_GUIDE.md  — Setup and configuration guide
  docs/RUNBOOK.md            — Operations runbook
EOF
}

# ─── Main ────────────────────────────────────────────────────────────────────

case "${1:-}" in
    init)           cmd_init ;;
    upload)         cmd_upload "${2:-}" "${3:-}" ;;
    publish)        cmd_publish ;;
    distribute)     cmd_distribute ;;
    sync)           cmd_sync ;;
    status)         cmd_status ;;
    snapshot)       cmd_snapshot "${2:-}" ;;
    retain)         cmd_retain ;;
    cleanup)        cmd_cleanup ;;
    repo-file)      cmd_repo_file "${2:-}" "${3:-}" ;;
    full-publish)   cmd_full_publish "${2:-}" "${3:-}" ;;
    -h|--help|help) usage ;;
    *)
        if [ -n "${1:-}" ]; then
            log_error "Unknown command: $1"
            echo ""
        fi
        usage
        exit 1
        ;;
esac
