#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# sign-packages.sh — GPG package signing with expiry-aware key validation
# ─────────────────────────────────────────────────────────────────────────────
#
# Signs RPM and DEB packages with GPG. Before signing, validates that the
# signing key exists and has not expired (or is not about to expire).
#
# Usage:
#   ./scripts/sign-packages.sh --type rpm --key-id ABCD1234 --directory ./output
#   ./scripts/sign-packages.sh --type deb --key-id ABCD1234 --directory ./output
#
# Options:
#   --type <rpm|deb>       Package format
#   --key-id <id>          GPG key ID for signing
#   --passphrase <pw>      GPG passphrase (prefer env GPG_PASSPHRASE)
#   --directory <path>     Directory containing packages to sign
#   --skip-expiry-check    Skip GPG key expiry validation
#   --expiry-warn-days <n> Days before expiry to warn (default: 90)
#
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ─── Colors ──────────────────────────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()    { echo -e "${BLUE}[INFO]${NC}    $*"; }
log_success() { echo -e "${GREEN}[OK]${NC}      $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}    $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC}   $*"; }

# ─── Defaults ────────────────────────────────────────────────────────────────

TYPE=""
KEY_ID=""
PASSPHRASE="${GPG_PASSPHRASE:-}"
DIRECTORY="."
SKIP_EXPIRY_CHECK=0
EXPIRY_WARN_DAYS=90

# ─── Parse Arguments ────────────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
    case $1 in
        --type)              TYPE="$2"; shift 2 ;;
        --key-id)            KEY_ID="$2"; shift 2 ;;
        --passphrase)        PASSPHRASE="$2"; shift 2 ;;
        --directory)         DIRECTORY="$2"; shift 2 ;;
        --skip-expiry-check) SKIP_EXPIRY_CHECK=1; shift ;;
        --expiry-warn-days)  EXPIRY_WARN_DAYS="$2"; shift 2 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# ─── Validate Inputs ────────────────────────────────────────────────────────

if [[ -z "$TYPE" ]] || [[ ! "$TYPE" =~ ^(rpm|deb)$ ]]; then
    log_error "Type must be 'rpm' or 'deb'"
    exit 1
fi

if [[ -z "$KEY_ID" ]]; then
    log_error "GPG key ID is required (--key-id)"
    exit 1
fi

if [[ ! -d "$DIRECTORY" ]]; then
    log_error "Directory not found: ${DIRECTORY}"
    exit 1
fi

# ─── GPG Key Expiry Check ───────────────────────────────────────────────────

check_key_expiry() {
    local key_id="$1"

    # Verify key exists in keyring
    if ! gpg --list-keys "$key_id" &>/dev/null; then
        log_error "GPG key not found in keyring: ${key_id}"
        return 1
    fi

    # Get expiry epoch from key
    local expiry_epoch
    expiry_epoch=$(gpg --with-colons --fixed-list-mode --list-keys "$key_id" 2>/dev/null \
        | grep "^pub:" | head -1 | cut -d: -f7)

    if [ -z "$expiry_epoch" ] || [ "$expiry_epoch" = "0" ]; then
        log_info "Key ${key_id} has no expiry date"
        return 0
    fi

    local now
    now=$(date +%s)
    local days_left=$(( (expiry_epoch - now) / 86400 ))
    local expiry_date
    expiry_date=$(date -d "@${expiry_epoch}" "+%Y-%m-%d" 2>/dev/null || \
                  date -r "$expiry_epoch" "+%Y-%m-%d" 2>/dev/null || \
                  echo "unknown")

    if [ "$days_left" -le 0 ]; then
        log_error "GPG key ${key_id} is EXPIRED (${expiry_date})"
        log_error "Refusing to sign packages with an expired key"
        log_error "Rotate key: ./scripts/gpg-key-manager.sh rotate"
        return 1
    elif [ "$days_left" -le 30 ]; then
        log_error "GPG key ${key_id} expires in ${days_left} days (${expiry_date})"
        log_error "Key rotation is critical — signed packages will become unverifiable"
        log_error "Rotate key: ./scripts/gpg-key-manager.sh rotate"
        return 1
    elif [ "$days_left" -le "$EXPIRY_WARN_DAYS" ]; then
        log_warn "GPG key ${key_id} expires in ${days_left} days (${expiry_date})"
        log_warn "Plan key rotation: ./scripts/gpg-key-manager.sh rotate"
        # Warning only — still allow signing
        return 0
    else
        log_info "GPG key ${key_id} valid for ${days_left} days (expires ${expiry_date})"
        return 0
    fi
}

# ─── Run Expiry Check ───────────────────────────────────────────────────────

if [ "$SKIP_EXPIRY_CHECK" != "1" ]; then
    if ! check_key_expiry "$KEY_ID"; then
        log_error "Key expiry check failed. Use --skip-expiry-check to override."
        exit 1
    fi
fi

# ─── Sign Packages ──────────────────────────────────────────────────────────

signed_count=0
failed_count=0

if [[ "$TYPE" == "rpm" ]]; then
    for rpm in "$DIRECTORY"/*.rpm; do
        [[ -f "$rpm" ]] || continue

        if [ -n "$PASSPHRASE" ]; then
            echo "$PASSPHRASE" | rpmsign --addsign --key-id="$KEY_ID" "$rpm" 2>/dev/null
        else
            rpmsign --addsign --key-id="$KEY_ID" "$rpm" 2>/dev/null
        fi

        if [ $? -eq 0 ]; then
            log_success "Signed: $(basename "$rpm")"
            signed_count=$((signed_count + 1))
        else
            log_error "Failed to sign: $(basename "$rpm")"
            failed_count=$((failed_count + 1))
        fi
    done
elif [[ "$TYPE" == "deb" ]]; then
    for deb in "$DIRECTORY"/*.deb; do
        [[ -f "$deb" ]] || continue

        dpkg-sig --sign builder -k "$KEY_ID" "$deb" 2>/dev/null

        if [ $? -eq 0 ]; then
            log_success "Signed: $(basename "$deb")"
            signed_count=$((signed_count + 1))
        else
            log_error "Failed to sign: $(basename "$deb")"
            failed_count=$((failed_count + 1))
        fi
    done
fi

# ─── Summary ─────────────────────────────────────────────────────────────────

if [ "$signed_count" -eq 0 ] && [ "$failed_count" -eq 0 ]; then
    log_warn "No ${TYPE} packages found in: ${DIRECTORY}"
elif [ "$failed_count" -gt 0 ]; then
    log_error "Signing complete: ${signed_count} signed, ${failed_count} failed"
    exit 1
else
    log_success "Signing complete: ${signed_count} packages signed"
fi
