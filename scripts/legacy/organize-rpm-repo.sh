#!/bin/bash
set -euo pipefail

SOURCE_DIR=""
DEST_DIR=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --source) SOURCE_DIR="$2"; shift 2 ;;
        --destination) DEST_DIR="$2"; shift 2 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

for rpm in "$SOURCE_DIR"/rpm-*/*.rpm; do
    [[ -f "$rpm" ]] || continue
    
    if [[ $rpm =~ \.([a-z]+[0-9]+)\.[^.]+\.rpm$ ]]; then
        distro="${BASH_REMATCH[1]}"
    else
        echo "Warning: Cannot determine distro for $rpm"
        continue
    fi
    
    arch=$(rpm -qp --queryformat '%{ARCH}' "$rpm")
    dest="$DEST_DIR/$distro/$arch"
    mkdir -p "$dest"
    cp -p "$rpm" "$dest/"
    echo "Organized: $(basename "$rpm") -> $distro/$arch/"
done
