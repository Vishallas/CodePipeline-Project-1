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

for deb in "$SOURCE_DIR"/deb-*/*.deb; do
    [[ -f "$deb" ]] || continue
    
    pkg_name=$(dpkg-deb -f "$deb" Package)
    
    if [[ $deb =~ deb-pg[0-9]+-([^-]+)- ]]; then
        dist="${BASH_REMATCH[1]}"
    else
        echo "Warning: Cannot determine distribution for $deb"
        continue
    fi
    
    first_letter="${pkg_name:0:1}"
    pool_dir="$DEST_DIR/$dist/pool/main/$first_letter/$pkg_name"
    mkdir -p "$pool_dir"
    cp -p "$deb" "$pool_dir/"
    echo "Organized: $(basename "$deb") -> $dist/pool/"
done
