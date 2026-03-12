#!/usr/bin/env bash
set -euo pipefail

REPO_URL="${1:?Repository URL required}"
SUFFIX="${2:-mydbops1}"
NEW_NAME="${3:-MyDBOps Enterprise Build System}"
NEW_EMAIL="${4:-build@mydbops.com}"

BUILD_ID="${CI_PIPELINE_ID:-$(date +%Y%m%d%H%M%S)}"
GIT_COMMIT="unknown"

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

echo "Cloning repository (depth=1)..."
git clone --depth 1 "$REPO_URL" "$WORKDIR/repo"
cd "$WORKDIR/repo"

GIT_COMMIT=$(git rev-parse --short HEAD)

CHANGELOG="debian/changelog"

if [[ ! -f "$CHANGELOG" ]]; then
    echo "ERROR: debian/changelog not found"
    exit 1
fi

FIRST_LINE=$(head -n 1 "$CHANGELOG")

if ! [[ "$FIRST_LINE" =~ ^([a-zA-Z0-9.+-]+)\ \(([^\)]+)\)\  ]]; then
    echo "ERROR: Invalid changelog format"
    exit 1
fi

PKG_NAME="${BASH_REMATCH[1]}"
CURRENT_VERSION="${BASH_REMATCH[2]}"

# Prevent duplicate processing
if [[ "$CURRENT_VERSION" == *"$SUFFIX"* ]]; then
    echo "Version already modified. Skipping."
    exit 0
fi

# Normalize upstream version
if [[ "$CURRENT_VERSION" == *"-"* ]]; then
    UPSTREAM="${CURRENT_VERSION%%-*}"
else
    UPSTREAM="$CURRENT_VERSION"
fi

NEW_VERSION="${UPSTREAM}-${SUFFIX}"

echo "Updating version: $CURRENT_VERSION → $NEW_VERSION"

# Update version in first line only
sed -i "1s|($CURRENT_VERSION)|($NEW_VERSION)|" "$CHANGELOG"

NEW_DATE="$(date -R)"

# Insert Enterprise build log after header line
awk -v name="$NEW_NAME" \
    -v email="$NEW_EMAIL" \
    -v date="$NEW_DATE" \
    -v build_id="$BUILD_ID" \
    -v commit="$GIT_COMMIT" \
    'BEGIN { header_done=0; signature_done=0 }
     NR==1 {
         print $0
         print ""
         print "  [ MyDBOps Enterprise Build ]"
         print "  * Enterprise downstream packaging."
         print "  * CI Build ID: " build_id
         print "  * Source Commit: " commit
         print ""
         next
     }
     /^ -- / && signature_done==0 {
         print " -- " name " <" email ">  " date
         signature_done=1
         next
     }
     { print }' "$CHANGELOG" > "${CHANGELOG}.tmp"

mv "${CHANGELOG}.tmp" "$CHANGELOG"

echo "Changelog successfully updated."
echo
echo "Preview:"
head -n 25 "$CHANGELOG"