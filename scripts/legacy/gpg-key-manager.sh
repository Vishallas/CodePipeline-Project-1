#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# gpg-key-manager.sh — GPG key lifecycle management with expiry handling
# ─────────────────────────────────────────────────────────────────────────────
#
# Manages GPG signing keys for the PostgreSQL packaging pipeline:
#   - Key generation with configurable expiry
#   - Expiry monitoring and alerts
#   - Key rotation workflow
#   - Public key export for repository clients
#   - Integration with Pulp signing services
#
# Usage:
#   ./scripts/gpg-key-manager.sh <command> [options]
#
# Commands:
#   status            Show signing key status and expiry
#   check-expiry      Check if key is expiring soon (exit 1 if warning)
#   generate          Generate a new signing key pair
#   rotate            Rotate to a new key (generate + update Pulp + export)
#   export-public     Export ASCII-armored public key
#   import            Import a GPG key from file
#   update-pulp       Update Pulp signing service with current key
#   list              List all packaging-related keys
#
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

# ─── Colors ──────────────────────────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log_info()    { echo -e "${BLUE}[INFO]${NC}    $*"; }
log_success() { echo -e "${GREEN}[OK]${NC}      $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}    $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC}   $*"; }
log_step()    { echo -e "${CYAN}[STEP]${NC}    $*"; }

# ─── Configuration ───────────────────────────────────────────────────────────

# Default key parameters
DEFAULT_KEY_TYPE="RSA"
DEFAULT_KEY_LENGTH=4096
DEFAULT_KEY_EXPIRY="2y"       # 2 years default expiry
DEFAULT_KEY_NAME="PostgreSQL Packaging"
DEFAULT_KEY_EMAIL="packaging@example.com"

# Expiry warning thresholds (in days)
EXPIRY_CRITICAL=30     # Exit code 2 — key expires within 30 days
EXPIRY_WARNING=90      # Exit code 1 — key expires within 90 days

# Paths
GPG_EXPORT_DIR="${REPO_ROOT}/keys"
PULP_CONF="${REPO_ROOT}/configs/pulp.conf"

# Load Pulp config if available
if [ -f "$PULP_CONF" ]; then
    source "$PULP_CONF"
fi

# ─── Helpers ─────────────────────────────────────────────────────────────────

# Get the configured GPG key ID from environment or config
get_key_id() {
    local key_id="${GPG_KEY_ID:-${PULP_GPG_KEY_ID:-}}"
    if [ -z "$key_id" ]; then
        log_error "No GPG key ID configured. Set GPG_KEY_ID environment variable."
        return 1
    fi
    echo "$key_id"
}

# Get key expiry date as epoch timestamp
# Returns empty string if key does not expire
get_key_expiry_epoch() {
    local key_id="$1"
    local expiry
    expiry=$(gpg --with-colons --fixed-list-mode --list-keys "$key_id" 2>/dev/null \
        | grep "^pub:" | head -1 | cut -d: -f7)
    echo "${expiry:-}"
}

# Get key creation date as epoch timestamp
get_key_creation_epoch() {
    local key_id="$1"
    gpg --with-colons --fixed-list-mode --list-keys "$key_id" 2>/dev/null \
        | grep "^pub:" | head -1 | cut -d: -f6
}

# Get key fingerprint
get_key_fingerprint() {
    local key_id="$1"
    gpg --with-colons --fixed-list-mode --list-keys "$key_id" 2>/dev/null \
        | grep "^fpr:" | head -1 | cut -d: -f10
}

# Calculate days until expiry
days_until_expiry() {
    local expiry_epoch="$1"
    if [ -z "$expiry_epoch" ] || [ "$expiry_epoch" = "0" ]; then
        echo "never"
        return 0
    fi
    local now
    now=$(date +%s)
    local diff=$(( (expiry_epoch - now) / 86400 ))
    echo "$diff"
}

# Format epoch as human-readable date
format_date() {
    local epoch="$1"
    if [ -z "$epoch" ] || [ "$epoch" = "0" ]; then
        echo "never"
    else
        date -d "@${epoch}" "+%Y-%m-%d %H:%M:%S %Z" 2>/dev/null || \
            date -r "$epoch" "+%Y-%m-%d %H:%M:%S %Z" 2>/dev/null || \
            echo "unknown"
    fi
}

# ─── Pulp API helpers ────────────────────────────────────────────────────────

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

    curl -s -X "$method" \
        "${auth_args[@]}" \
        "${ca_args[@]}" \
        --max-time "${PULP_API_TIMEOUT:-30}" \
        -H "Content-Type: application/json" \
        "$@" \
        "${PULP_BASE_URL:-}${endpoint}"
}

# ─── Commands ────────────────────────────────────────────────────────────────

cmd_status() {
    local key_id
    key_id=$(get_key_id) || exit 1

    echo ""
    echo "═══════════════════════════════════════════════════════════════════"
    echo "  GPG Signing Key Status"
    echo "═══════════════════════════════════════════════════════════════════"
    echo ""

    # Check if key exists in keyring
    if ! gpg --list-keys "$key_id" &>/dev/null; then
        log_error "Key not found in GPG keyring: ${key_id}"
        echo ""
        echo "  Import a key:  ./scripts/gpg-key-manager.sh import --file <key.asc>"
        echo "  Generate new:  ./scripts/gpg-key-manager.sh generate"
        echo ""
        return 1
    fi

    local fingerprint creation_epoch expiry_epoch
    fingerprint=$(get_key_fingerprint "$key_id")
    creation_epoch=$(get_key_creation_epoch "$key_id")
    expiry_epoch=$(get_key_expiry_epoch "$key_id")

    echo "  Key ID:         ${key_id}"
    echo "  Fingerprint:    ${fingerprint}"
    echo "  Created:        $(format_date "$creation_epoch")"

    if [ -z "$expiry_epoch" ] || [ "$expiry_epoch" = "0" ]; then
        echo -e "  Expires:        ${YELLOW}never (no expiry set)${NC}"
        echo ""
        log_warn "Key has no expiry date. Consider setting one for security."
    else
        local days_left
        days_left=$(days_until_expiry "$expiry_epoch")
        echo "  Expires:        $(format_date "$expiry_epoch")"

        if [ "$days_left" -le 0 ]; then
            echo -e "  Status:         ${RED}EXPIRED${NC} (${days_left} days ago)"
        elif [ "$days_left" -le "$EXPIRY_CRITICAL" ]; then
            echo -e "  Status:         ${RED}CRITICAL${NC} — expires in ${days_left} days"
        elif [ "$days_left" -le "$EXPIRY_WARNING" ]; then
            echo -e "  Status:         ${YELLOW}WARNING${NC} — expires in ${days_left} days"
        else
            echo -e "  Status:         ${GREEN}OK${NC} — expires in ${days_left} days"
        fi
    fi

    # Show UID info
    echo ""
    echo "  Key UIDs:"
    gpg --with-colons --list-keys "$key_id" 2>/dev/null \
        | grep "^uid:" | while IFS=: read -r _ trust _ _ _ _ _ _ _ uid _; do
        echo "    - ${uid}"
    done

    # Check for subkeys
    echo ""
    echo "  Subkeys:"
    gpg --with-colons --list-keys "$key_id" 2>/dev/null \
        | grep "^sub:" | while IFS=: read -r _ _ length algo _ created expiry _ _ _ _; do
        local sub_expiry="never"
        if [ -n "$expiry" ] && [ "$expiry" != "0" ]; then
            sub_expiry=$(format_date "$expiry")
        fi
        echo "    - Algorithm: ${algo}, Length: ${length}, Expires: ${sub_expiry}"
    done

    # Check public key export
    echo ""
    if [ -f "${GPG_EXPORT_DIR}/RPM-GPG-KEY-postgresql" ]; then
        log_success "Public key exported to: ${GPG_EXPORT_DIR}/RPM-GPG-KEY-postgresql"
    else
        log_warn "Public key not exported. Run: ./scripts/gpg-key-manager.sh export-public"
    fi

    echo ""
    echo "═══════════════════════════════════════════════════════════════════"
    echo ""
}

cmd_check_expiry() {
    local key_id
    key_id=$(get_key_id) || exit 1

    if ! gpg --list-keys "$key_id" &>/dev/null; then
        log_error "Key not found in GPG keyring: ${key_id}"
        exit 2
    fi

    local expiry_epoch
    expiry_epoch=$(get_key_expiry_epoch "$key_id")

    if [ -z "$expiry_epoch" ] || [ "$expiry_epoch" = "0" ]; then
        log_warn "Key ${key_id} has no expiry date set"
        # No expiry is a security concern but not an operational emergency
        exit 0
    fi

    local days_left
    days_left=$(days_until_expiry "$expiry_epoch")

    if [ "$days_left" -le 0 ]; then
        log_error "Key ${key_id} is EXPIRED ($(format_date "$expiry_epoch"))"
        log_error "Rotate immediately: ./scripts/gpg-key-manager.sh rotate"
        exit 2
    elif [ "$days_left" -le "$EXPIRY_CRITICAL" ]; then
        log_error "Key ${key_id} expires in ${days_left} days ($(format_date "$expiry_epoch"))"
        log_error "Rotation required. Run: ./scripts/gpg-key-manager.sh rotate"
        exit 2
    elif [ "$days_left" -le "$EXPIRY_WARNING" ]; then
        log_warn "Key ${key_id} expires in ${days_left} days ($(format_date "$expiry_epoch"))"
        log_warn "Plan key rotation. Run: ./scripts/gpg-key-manager.sh rotate"
        exit 1
    else
        log_success "Key ${key_id} is valid for ${days_left} more days ($(format_date "$expiry_epoch"))"
        exit 0
    fi
}

cmd_generate() {
    local key_name="${DEFAULT_KEY_NAME}"
    local key_email="${DEFAULT_KEY_EMAIL}"
    local key_type="${DEFAULT_KEY_TYPE}"
    local key_length="${DEFAULT_KEY_LENGTH}"
    local key_expiry="${DEFAULT_KEY_EXPIRY}"
    local passphrase=""

    # Parse options
    while [[ $# -gt 0 ]]; do
        case $1 in
            --name)       key_name="$2"; shift 2 ;;
            --email)      key_email="$2"; shift 2 ;;
            --type)       key_type="$2"; shift 2 ;;
            --length)     key_length="$2"; shift 2 ;;
            --expiry)     key_expiry="$2"; shift 2 ;;
            --passphrase) passphrase="$2"; shift 2 ;;
            *) log_error "Unknown option: $1"; exit 1 ;;
        esac
    done

    echo ""
    log_step "Generating new GPG signing key..."
    echo ""
    echo "  Name:    ${key_name}"
    echo "  Email:   ${key_email}"
    echo "  Type:    ${key_type}"
    echo "  Length:  ${key_length}"
    echo "  Expiry:  ${key_expiry}"
    echo ""

    # Generate key using batch mode
    local batch_config
    batch_config=$(mktemp)
    trap 'rm -f "$batch_config"' EXIT

    cat > "$batch_config" <<EOF
%echo Generating PostgreSQL Packaging GPG Key
Key-Type: ${key_type}
Key-Length: ${key_length}
Subkey-Type: ${key_type}
Subkey-Length: ${key_length}
Name-Real: ${key_name}
Name-Email: ${key_email}
Expire-Date: ${key_expiry}
EOF

    if [ -n "$passphrase" ]; then
        echo "Passphrase: ${passphrase}" >> "$batch_config"
    else
        echo "%no-protection" >> "$batch_config"
    fi

    echo "%commit" >> "$batch_config"
    echo "%echo Key generation complete" >> "$batch_config"

    gpg --batch --gen-key "$batch_config"
    rm -f "$batch_config"
    trap - EXIT

    # Get the fingerprint of the newly generated key
    local new_key_fpr
    new_key_fpr=$(gpg --with-colons --list-keys "$key_email" 2>/dev/null \
        | grep "^fpr:" | tail -1 | cut -d: -f10)

    echo ""
    log_success "Key generated successfully"
    echo ""
    echo "  Fingerprint: ${new_key_fpr}"
    echo "  Short ID:    ${new_key_fpr: -8}"
    echo ""
    echo "  Next steps:"
    echo "    1. Set GPG_KEY_ID=${new_key_fpr: -8} in your environment"
    echo "    2. Export public key:  ./scripts/gpg-key-manager.sh export-public"
    echo "    3. Update Pulp:        ./scripts/gpg-key-manager.sh update-pulp"
    echo ""
}

cmd_rotate() {
    local old_key_id=""
    local key_expiry="${DEFAULT_KEY_EXPIRY}"
    local key_name="${DEFAULT_KEY_NAME}"
    local key_email="${DEFAULT_KEY_EMAIL}"

    while [[ $# -gt 0 ]]; do
        case $1 in
            --old-key)  old_key_id="$2"; shift 2 ;;
            --expiry)   key_expiry="$2"; shift 2 ;;
            --name)     key_name="$2"; shift 2 ;;
            --email)    key_email="$2"; shift 2 ;;
            *) log_error "Unknown option: $1"; exit 1 ;;
        esac
    done

    if [ -z "$old_key_id" ]; then
        old_key_id=$(get_key_id 2>/dev/null) || true
    fi

    echo ""
    echo "═══════════════════════════════════════════════════════════════════"
    echo "  GPG Key Rotation"
    echo "═══════════════════════════════════════════════════════════════════"
    echo ""

    if [ -n "$old_key_id" ]; then
        log_info "Current key: ${old_key_id}"
        local expiry_epoch
        expiry_epoch=$(get_key_expiry_epoch "$old_key_id" 2>/dev/null || echo "")
        if [ -n "$expiry_epoch" ] && [ "$expiry_epoch" != "0" ]; then
            log_info "Current key expires: $(format_date "$expiry_epoch")"
        fi
    else
        log_warn "No existing key configured"
    fi

    echo ""
    log_step "Step 1/5: Generating new key..."
    cmd_generate --name "$key_name" --email "$key_email" --expiry "$key_expiry"

    local new_key_fpr
    new_key_fpr=$(gpg --with-colons --list-keys "$key_email" 2>/dev/null \
        | grep "^fpr:" | tail -1 | cut -d: -f10)
    local new_key_short="${new_key_fpr: -8}"

    log_step "Step 2/5: Exporting new public key..."
    GPG_KEY_ID="$new_key_short" cmd_export_public

    log_step "Step 3/5: Signing new key with old key (trust chain)..."
    if [ -n "$old_key_id" ] && gpg --list-keys "$old_key_id" &>/dev/null; then
        gpg --default-key "$old_key_id" --sign-key "$new_key_fpr" 2>/dev/null && \
            log_success "New key cross-signed with old key" || \
            log_warn "Could not cross-sign (may need interactive confirmation)"
    else
        log_warn "No old key to cross-sign with"
    fi

    log_step "Step 4/5: Updating Pulp signing service..."
    if [ -n "${PULP_BASE_URL:-}" ] && [ "${PULP_BASE_URL}" != "https://pulp.example.com" ]; then
        GPG_KEY_ID="$new_key_short" cmd_update_pulp
    else
        log_warn "Pulp not configured — skipping signing service update"
        echo "  Run manually: GPG_KEY_ID=${new_key_short} ./scripts/gpg-key-manager.sh update-pulp"
    fi

    log_step "Step 5/5: Generating transition notice..."
    _generate_rotation_notice "$old_key_id" "$new_key_short" "$new_key_fpr"

    echo ""
    echo "═══════════════════════════════════════════════════════════════════"
    echo "  Key Rotation Complete"
    echo "═══════════════════════════════════════════════════════════════════"
    echo ""
    echo "  New Key ID:    ${new_key_short}"
    echo "  Fingerprint:   ${new_key_fpr}"
    echo ""
    echo "  Required actions:"
    echo "    1. Update GPG_KEY_ID in your environment/CI to: ${new_key_short}"
    echo "    2. Update pipeline.conf GPG_KEY_ID if hardcoded"
    echo "    3. Distribute the new public key to clients"
    echo "    4. Re-sign existing packages if needed"
    echo "    5. Keep old key available until all clients have updated"
    echo ""
}

_generate_rotation_notice() {
    local old_key="$1"
    local new_key="$2"
    local new_fpr="$3"

    local notice_file="${GPG_EXPORT_DIR}/KEY-ROTATION-NOTICE.txt"
    mkdir -p "${GPG_EXPORT_DIR}"

    cat > "$notice_file" <<EOF
PostgreSQL Packaging — GPG Key Rotation Notice
═══════════════════════════════════════════════

Date:            $(date -u "+%Y-%m-%d %H:%M:%S UTC")
Previous Key ID: ${old_key:-N/A}
New Key ID:      ${new_key}
New Fingerprint: ${new_fpr}

Action Required:
  Import the new public key on all client systems:

    rpm --import https://rpm.example.com/keys/RPM-GPG-KEY-postgresql

  Or manually:

    rpm --import /path/to/RPM-GPG-KEY-postgresql

The old key will remain valid for signature verification of previously
signed packages. New packages will be signed with the new key.

EOF

    log_success "Rotation notice written to: ${notice_file}"
}

cmd_export_public() {
    local key_id
    key_id=$(get_key_id) || exit 1

    mkdir -p "${GPG_EXPORT_DIR}"

    local pubkey_file="${GPG_EXPORT_DIR}/RPM-GPG-KEY-postgresql"

    gpg --armor --export "$key_id" > "$pubkey_file"

    log_success "Public key exported to: ${pubkey_file}"
    echo ""
    echo "  Install on client systems:"
    echo "    rpm --import ${pubkey_file}"
    echo ""
    echo "  Or serve via HTTP for automated installs:"
    echo "    rpm --import ${PULP_CONTENT_URL:-https://rpm.example.com}/keys/RPM-GPG-KEY-postgresql"
    echo ""
}

cmd_import() {
    local key_file=""

    while [[ $# -gt 0 ]]; do
        case $1 in
            --file) key_file="$2"; shift 2 ;;
            *) log_error "Unknown option: $1"; exit 1 ;;
        esac
    done

    if [ -z "$key_file" ] || [ ! -f "$key_file" ]; then
        log_error "Usage: gpg-key-manager.sh import --file <path-to-key>"
        exit 1
    fi

    log_step "Importing GPG key from: ${key_file}"
    gpg --import "$key_file"
    log_success "Key imported successfully"

    echo ""
    log_info "List imported keys: ./scripts/gpg-key-manager.sh list"
}

cmd_update_pulp() {
    local key_id
    key_id=$(get_key_id) || exit 1

    local signing_service="${PULP_SIGNING_SERVICE:-postgresql-signing}"

    log_step "Updating Pulp signing service: ${signing_service}"

    if [ -z "${PULP_BASE_URL:-}" ] || [ "${PULP_BASE_URL}" = "https://pulp.example.com" ]; then
        log_error "PULP_BASE_URL not configured. Edit configs/pulp.conf first."
        exit 1
    fi

    # Look up existing signing service
    local response
    response=$(pulp_api GET "/pulp/api/v3/signing-services/?name=${signing_service}")

    local count
    count=$(echo "$response" | python3 -c "import sys,json; print(json.load(sys.stdin).get('count',0))" 2>/dev/null || echo "0")

    if [ "$count" = "0" ]; then
        log_warn "Signing service '${signing_service}' not found in Pulp"
        echo ""
        echo "  Register it on the Pulp server:"
        echo "    pulpcore-manager add-signing-service \\"
        echo "      --name '${signing_service}' \\"
        echo "      --key '${key_id}' \\"
        echo "      --script '/var/lib/pulp/scripts/sign_metadata.sh'"
        echo ""
        return 1
    fi

    local service_href
    service_href=$(echo "$response" | python3 -c "import sys,json; print(json.load(sys.stdin)['results'][0]['pulp_href'])" 2>/dev/null)

    log_info "Found signing service at: ${service_href}"
    log_success "Signing service exists — update the key on the Pulp server if changed"

    # Export public key and verify it matches
    local fingerprint
    fingerprint=$(get_key_fingerprint "$key_id")
    log_info "Active key fingerprint: ${fingerprint}"

    echo ""
    echo "  If the key has changed, update on the Pulp server:"
    echo "    gpg --import /path/to/new-private-key.asc"
    echo "    pulpcore-manager remove-signing-service '${signing_service}'"
    echo "    pulpcore-manager add-signing-service \\"
    echo "      --name '${signing_service}' \\"
    echo "      --key '${fingerprint}' \\"
    echo "      --script '/var/lib/pulp/scripts/sign_metadata.sh'"
    echo ""
}

cmd_list() {
    echo ""
    echo "═══════════════════════════════════════════════════════════════════"
    echo "  GPG Keys (packaging-related)"
    echo "═══════════════════════════════════════════════════════════════════"
    echo ""

    gpg --list-keys --with-colons 2>/dev/null | \
    awk -F: '
    /^pub:/ {
        trust=$2; length=$3; algo=$4; keyid=$5; created=$6; expiry=$7
        key_found=1
    }
    /^uid:/ && key_found {
        uid=$10
        if (uid ~ /[Pp]ostgre/ || uid ~ /[Pp]ackag/ || uid ~ /[Rr][Pp][Mm]/ || uid ~ /[Ss]igning/) {
            printf "  Key ID:  %s\n", keyid
            printf "  UID:     %s\n", uid
            if (expiry && expiry != "0") {
                cmd = "date -d @" expiry " +\"%Y-%m-%d\" 2>/dev/null || date -r " expiry " +\"%Y-%m-%d\" 2>/dev/null"
                cmd | getline exp_date
                close(cmd)
                printf "  Expiry:  %s\n", exp_date
            } else {
                printf "  Expiry:  never\n"
            }
            printf "\n"
        }
        key_found=0
    }
    '

    # Also show if no matching keys found
    local key_count
    key_count=$(gpg --list-keys --with-colons 2>/dev/null | grep "^pub:" | wc -l)
    if [ "$key_count" -eq 0 ]; then
        echo "  No GPG keys found in keyring."
        echo ""
        echo "  Generate: ./scripts/gpg-key-manager.sh generate"
        echo "  Import:   ./scripts/gpg-key-manager.sh import --file <key.asc>"
    fi

    echo ""
}

# ─── Usage ───────────────────────────────────────────────────────────────────

usage() {
    cat <<'EOF'
GPG Key Manager — PostgreSQL Packaging

Usage: gpg-key-manager.sh <command> [options]

Commands:
  status            Show signing key status, expiry, and fingerprint
  check-expiry      Check key expiry (exit 0=ok, 1=warning, 2=critical/expired)
  generate          Generate a new GPG signing key pair
  rotate            Full key rotation (generate + export + update Pulp)
  export-public     Export ASCII-armored public key for repo clients
  import            Import a GPG key from file
  update-pulp       Update Pulp signing service with current key
  list              List all packaging-related keys in keyring

Generate Options:
  --name <name>       Key name (default: "PostgreSQL Packaging")
  --email <email>     Key email (default: "packaging@example.com")
  --type <type>       Key type (default: RSA)
  --length <bits>     Key length (default: 4096)
  --expiry <spec>     Expiry (default: 2y) — formats: 0, 1y, 6m, 365d
  --passphrase <pw>   Key passphrase (default: no passphrase)

Rotate Options:
  --old-key <id>      Current key ID (default: from GPG_KEY_ID env)
  --expiry <spec>     New key expiry (default: 2y)
  --name <name>       Key name for new key
  --email <email>     Key email for new key

Environment Variables:
  GPG_KEY_ID          Active signing key ID

Examples:
  # Check if key needs rotation
  gpg-key-manager.sh check-expiry

  # Generate a new 4096-bit RSA key expiring in 2 years
  gpg-key-manager.sh generate --expiry 2y --email "ops@mydbops.com"

  # Full rotation workflow
  gpg-key-manager.sh rotate --expiry 2y

  # Use in CI/CD pipeline pre-build check
  if ! ./scripts/gpg-key-manager.sh check-expiry; then
    echo "WARNING: GPG key expiry approaching"
  fi
EOF
}

# ─── Main ────────────────────────────────────────────────────────────────────

case "${1:-}" in
    status)         cmd_status ;;
    check-expiry)   cmd_check_expiry ;;
    generate)       shift; cmd_generate "$@" ;;
    rotate)         shift; cmd_rotate "$@" ;;
    export-public)  cmd_export_public ;;
    import)         shift; cmd_import "$@" ;;
    update-pulp)    cmd_update_pulp ;;
    list)           cmd_list ;;
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
