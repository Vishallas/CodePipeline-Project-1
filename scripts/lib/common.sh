#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# scripts/lib/common.sh — Shared utilities for pg-platform build scripts
#
# Source this file at the top of every script:
#   source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
#   # or from buildspecs:
#   source "$PLATFORM_DIR/scripts/lib/common.sh"
# ─────────────────────────────────────────────────────────────────────────────

# Guard double-sourcing
[[ -n "${_MYDBOPS_COMMON_LOADED:-}" ]] && return 0
_MYDBOPS_COMMON_LOADED=1

# ─── Colors ──────────────────────────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# ─── Logging ─────────────────────────────────────────────────────────────────

_log_ts() { date '+%Y-%m-%d %H:%M:%S'; }

log_info()    { echo -e "${BLUE}[$(_log_ts)] [INFO]${NC}    $*" >&2; }
log_success() { echo -e "${GREEN}[$(_log_ts)] [OK]${NC}      $*" >&2; }
log_warn()    { echo -e "${YELLOW}[$(_log_ts)] [WARN]${NC}    $*" >&2; }
log_error()   { echo -e "${RED}[$(_log_ts)] [ERROR]${NC}   $*" >&2; }
log_step()    { echo -e "${CYAN}[$(_log_ts)] [STEP]${NC}    $*" >&2; }
log_build()   { echo -e "${BOLD}[$(_log_ts)] [BUILD]${NC}   $*" >&2; }

# ─── YAML helpers ────────────────────────────────────────────────────────────

# yaml_get <file> <dotted.key>
# Returns the scalar value at the given dotted key path.
# Tries yq first; falls back to python3.
yaml_get() {
    local file="$1"
    local key="$2"

    if command -v yq &>/dev/null; then
        yq e ".${key}" "$file" 2>/dev/null
        return
    fi

    # Python 3.6-compatible fallback (no walrus operator)
    python3 - "$file" "$key" <<'PYEOF'
import sys
import yaml

def get_nested(data, key_path):
    parts = key_path.split('.')
    current = data
    for part in parts:
        if isinstance(current, dict):
            current = current.get(part)
        else:
            return None
        if current is None:
            return None
    return current

with open(sys.argv[1]) as f:
    data = yaml.safe_load(f)

result = get_nested(data, sys.argv[2])
if result is not None:
    print(result)
PYEOF
}

# yaml_get_list <file> <dotted.key>
# Returns list items, one per line.
yaml_get_list() {
    local file="$1"
    local key="$2"

    if command -v yq &>/dev/null; then
        yq e ".${key}[]" "$file" 2>/dev/null
        return
    fi

    python3 - "$file" "$key" <<'PYEOF'
import sys
import yaml

def get_nested(data, key_path):
    parts = key_path.split('.')
    current = data
    for part in parts:
        if isinstance(current, dict):
            current = current.get(part)
        else:
            return None
        if current is None:
            return None
    return current

with open(sys.argv[1]) as f:
    data = yaml.safe_load(f)

result = get_nested(data, sys.argv[2])
if isinstance(result, list):
    for item in result:
        print(item)
elif result is not None:
    print(result)
PYEOF
}

# ─── Dependency checking ──────────────────────────────────────────────────────

# check_deps dep1 dep2 ...
# Collects all missing deps before failing so the user sees everything at once.
check_deps() {
    local missing=()
    for dep in "$@"; do
        if ! command -v "$dep" &>/dev/null; then
            missing+=("$dep")
        fi
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing required dependencies: ${missing[*]}"
        log_error "Install them before running this script."
        return 1
    fi
}

# ─── SHA256 helpers ───────────────────────────────────────────────────────────

# sha256_file <path>
# Prints the hex SHA256 of the file (no filename).
sha256_file() {
    local path="$1"
    if command -v sha256sum &>/dev/null; then
        sha256sum "$path" | awk '{print $1}'
    elif command -v shasum &>/dev/null; then
        shasum -a 256 "$path" | awk '{print $1}'
    else
        log_error "Neither sha256sum nor shasum found"
        return 1
    fi
}

# verify_sha256 <path> <expected_hex>
# Fails if actual SHA256 does not match expected.  No-op if expected is empty.
verify_sha256() {
    local path="$1"
    local expected="$2"
    [[ -z "$expected" ]] && return 0

    local actual
    actual=$(sha256_file "$path")
    if [[ "$actual" != "$expected" ]]; then
        log_error "SHA256 mismatch for $(basename "$path")"
        log_error "  expected: $expected"
        log_error "  actual:   $actual"
        return 1
    fi
    log_success "SHA256 verified: $(basename "$path")"
}

# ─── Download ─────────────────────────────────────────────────────────────────

# download_tarball <url> <dest> [expected_sha256]
# Downloads with retry; verifies sha256 if non-empty.
download_tarball() {
    local url="$1"
    local dest="$2"
    local expected_sha256="${3:-}"

    log_info "Downloading: $url"
    if ! curl -fsSL --retry 3 --retry-delay 5 -o "$dest" "$url"; then
        log_error "Failed to download: $url"
        return 1
    fi
    log_success "Downloaded: $(basename "$dest") ($(du -sh "$dest" | cut -f1))"
    verify_sha256 "$dest" "$expected_sha256"
}

# ─── ECR ──────────────────────────────────────────────────────────────────────

# ecr_login <region> <account_id>
ecr_login() {
    local region="$1"
    local account_id="$2"
    log_info "Logging into ECR: ${account_id}.dkr.ecr.${region}.amazonaws.com"
    aws ecr get-login-password --region "$region" \
        | docker login --username AWS --password-stdin \
          "${account_id}.dkr.ecr.${region}.amazonaws.com"
}

# ecr_image_uri <account_id> <region> <repo> <tag>
ecr_image_uri() {
    local account_id="$1"
    local region="$2"
    local repo="$3"
    local tag="$4"
    echo "${account_id}.dkr.ecr.${region}.amazonaws.com/${repo}:${tag}"
}

# ─── Target helpers ───────────────────────────────────────────────────────────

# target_to_docker_tag <os> <release> <arch>
# Returns the Docker image tag for a given build target.
target_to_docker_tag() {
    local os="$1"
    local release="$2"
    local arch="$3"
    case "${os}-${release}-${arch}" in
        ubuntu-20-amd64)   echo "ubuntu-20.04-amd64" ;;
        ubuntu-22-amd64)   echo "ubuntu-22.04-amd64" ;;
        ubuntu-22-arm64)   echo "ubuntu-22.04-arm64" ;;
        ubuntu-24-amd64)   echo "ubuntu-24.04-amd64" ;;
        ubuntu-24-arm64)   echo "ubuntu-24.04-arm64" ;;
        epel-8-x86_64)     echo "el8-x86_64" ;;
        epel-8-aarch64)    echo "el8-aarch64" ;;
        epel-9-x86_64)     echo "el9-x86_64" ;;
        epel-9-aarch64)    echo "el9-aarch64" ;;
        epel-10-x86_64)    echo "el10-x86_64" ;;
        fedora-42-x86_64)  echo "fedora-42-x86_64" ;;
        fedora-43-x86_64)  echo "fedora-43-x86_64" ;;
        *)
            log_error "Unknown build target: os=${os} release=${release} arch=${arch}"
            return 1
            ;;
    esac
}

# target_to_s3_label <os> <release> <arch>
# Returns the S3 directory label for a given build target (e.g. ubuntu-22-amd64).
target_to_s3_label() {
    local os="$1"
    local release="$2"
    local arch="$3"
    case "$os" in
        ubuntu) echo "ubuntu-${release}-${arch}" ;;
        epel)   echo "epel-${release}-${arch}" ;;
        fedora) echo "f${release}-${arch}" ;;
        *)
            log_error "Unknown OS for s3 label: $os"
            return 1
            ;;
    esac
}

# target_pkg_type <os>
# Returns "deb" for ubuntu targets, "rpm" for epel/fedora.
target_pkg_type() {
    local os="$1"
    case "$os" in
        ubuntu)         echo "deb" ;;
        epel|fedora)    echo "rpm" ;;
        *)
            log_error "Unknown OS for pkg type: $os"
            return 1
            ;;
    esac
}

# release_to_codename <os> <release>
# Maps ubuntu release number to Debian codename.
release_to_codename() {
    local os="$1"
    local release="$2"
    if [[ "$os" != "ubuntu" ]]; then
        echo ""
        return
    fi
    case "$release" in
        20) echo "focal" ;;
        22) echo "jammy" ;;
        24) echo "noble" ;;
        *)
            log_warn "Unknown ubuntu release for codename: $release"
            echo "unknown"
            ;;
    esac
}

# ─── S3 helpers ───────────────────────────────────────────────────────────────

# s3_build_path <bucket> <env> <name> <version> <label>
# Returns canonical S3 prefix (no trailing slash).
s3_build_path() {
    local bucket="$1"
    local env="$2"
    local name="$3"
    local version="$4"
    local label="$5"
    echo "s3://${bucket}/${env}/packages/${name}/${version}/${label}"
}

# s3_upload <local_path> <s3_path>
# Uploads file, generates .sha256 sidecar, verifies upload with head-object.
s3_upload() {
    local local_path="$1"
    local s3_path="$2"
    local sha256_path="${local_path}.sha256"

    # Generate sha256 sidecar
    sha256_file "$local_path" > "$sha256_path"

    log_info "Uploading: $(basename "$local_path") → $s3_path"
    aws s3 cp "$local_path" "$s3_path"
    aws s3 cp "$sha256_path" "${s3_path}.sha256"

    # Verify with head-object
    if ! aws s3api head-object \
            --bucket "$(echo "$s3_path" | sed 's|s3://\([^/]*\)/.*|\1|')" \
            --key "$(echo "$s3_path" | sed 's|s3://[^/]*/||')" \
            &>/dev/null; then
        log_error "Upload verification failed: $s3_path"
        return 1
    fi
    log_success "Uploaded: $(basename "$local_path")"
}

# ─── GPG helpers ─────────────────────────────────────────────────────────────

# gpg_import_key <base64_encoded_key>
# Imports a base64-encoded GPG private key; sets GPG_KEY_ID.
gpg_import_key() {
    local base64_key="$1"
    [[ -z "$base64_key" ]] && return 0

    log_info "Importing GPG signing key..."
    echo "$base64_key" | base64 -d | gpg --batch --import 2>/dev/null || true
    GPG_KEY_ID=$(gpg --list-secret-keys --keyid-format LONG 2>/dev/null \
        | grep "^sec" | awk '{print $2}' | cut -d'/' -f2 | head -1)
    if [[ -n "$GPG_KEY_ID" ]]; then
        log_success "GPG key imported: $GPG_KEY_ID"
    else
        log_warn "GPG key import completed but no key ID found"
    fi
    export GPG_KEY_ID
}

# gpg_sign_deb <deb_file> <key_id>
# Signs a .deb with dpkg-sig. Skips if key_id is empty.
gpg_sign_deb() {
    local deb_file="$1"
    local key_id="${2:-${GPG_KEY_ID:-}}"
    [[ -z "$key_id" ]] && { log_warn "No GPG key — skipping deb signing"; return 0; }
    log_info "Signing deb: $(basename "$deb_file")"
    dpkg-sig --sign builder -k "$key_id" "$deb_file" 2>/dev/null || \
        log_warn "dpkg-sig failed for $(basename "$deb_file") — continuing"
}

# gpg_sign_rpm <rpm_file> <key_id>
# Signs an .rpm with rpm --addsign. Skips if key_id is empty.
gpg_sign_rpm() {
    local rpm_file="$1"
    local key_id="${2:-${GPG_KEY_ID:-}}"
    [[ -z "$key_id" ]] && { log_warn "No GPG key — skipping rpm signing"; return 0; }
    log_info "Signing rpm: $(basename "$rpm_file")"
    rpm --addsign "$rpm_file" 2>/dev/null || \
        log_warn "rpm --addsign failed for $(basename "$rpm_file") — continuing"
}

# gpg_setup_rpmmacros <key_id>
# Writes ~/.rpmmacros for rpm signing.
gpg_setup_rpmmacros() {
    local key_id="${1:-${GPG_KEY_ID:-}}"
    [[ -z "$key_id" ]] && return 0
    cat > "${HOME}/.rpmmacros" <<EOF
%_signature gpg
%_gpg_path ${HOME}/.gnupg
%_gpg_name ${key_id}
%__gpg /usr/bin/gpg
EOF
    log_info "~/.rpmmacros configured for key: $key_id"
}

# ─── Secrets Manager ──────────────────────────────────────────────────────────

# secrets_manager_get <secret_name>
# Returns the secret string value. Prints to stdout.
secrets_manager_get() {
    local secret_name="$1"
    aws secretsmanager get-secret-value \
        --secret-id "$secret_name" \
        --query SecretString \
        --output text
}
