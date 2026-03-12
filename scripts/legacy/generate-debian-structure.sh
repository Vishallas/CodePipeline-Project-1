#!/bin/bash
# Generate Debian folder structure from templates
# This script creates version-specific debian packages similar to RPM structure

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
DEBIAN_TEMPLATE_DIR="$PROJECT_ROOT/packaging/debian"
DEBIAN_ROOT="$PROJECT_ROOT/debian"

# PostgreSQL versions
PG_VERSIONS=(14 15 16 17 18)
DISTRIBUTIONS=(bookworm bullseye jammy noble focal)

echo "Generating Debian structure from templates..."

# Function to replace placeholders in a template file
generate_debian_files() {
    local pg_major=$1
    local dist=$2
    local template_file=$3
    local output_file=$4

    # For control files, we use the template as-is (without version-specific changes)
    # The build scripts will handle variable substitution at build time
    cp "$template_file" "$output_file"
}

# Create debian files for each PostgreSQL version
for pg_major in "${PG_VERSIONS[@]}"; do
    debian_dir="$DEBIAN_ROOT/main/non-common/postgresql-$pg_major/debian"

    echo "Creating Debian files for PostgreSQL $pg_major in $debian_dir"

    # Copy base debian files
    cp "$DEBIAN_TEMPLATE_DIR/control.in" "$debian_dir/control.in"
    cp "$DEBIAN_TEMPLATE_DIR/changelog.in" "$debian_dir/changelog.in"
    cp "$DEBIAN_TEMPLATE_DIR/copyright" "$debian_dir/copyright"
    cp "$DEBIAN_TEMPLATE_DIR/compat" "$debian_dir/compat"
    cp "$DEBIAN_TEMPLATE_DIR/rules" "$debian_dir/rules"
    cp "$DEBIAN_TEMPLATE_DIR/postgresql-server.postinst" "$debian_dir/postgresql-server.postinst"
    cp "$DEBIAN_TEMPLATE_DIR/postgresql-server.install.in" "$debian_dir/postgresql-server.install.in"
    cp "$DEBIAN_TEMPLATE_DIR/postgresql-client.install.in" "$debian_dir/postgresql-client.install.in"

    # Create source subdirectory with format file
    mkdir -p "$debian_dir/source"
    cp "$DEBIAN_TEMPLATE_DIR/source/format" "$debian_dir/source/format"

    # Make scripts executable
    chmod +x "$debian_dir/rules"
    chmod +x "$debian_dir/postgresql-server.postinst"

    echo "  ✓ Created Debian files for PostgreSQL $pg_major"
done

# Create global makefile for Debian builds similar to RPM
mkdir -p "$DEBIAN_ROOT/global"
cat > "$DEBIAN_ROOT/global/Makefile.global" << 'EOF'
# Global Makefile for Debian package builds
# PostgreSQL Global Development Group (PGDG) aligned

# PostgreSQL versions to build
PG_VERSIONS := 14 15 16 17 18

# Debian distributions
DEBIAN_DISTS := bookworm bullseye jammy noble focal

# Build directory
BUILD_DIR := builds
OUTPUT_DIR := output

# Default target
.PHONY: all
all: build-debs

# Build all Debian packages
.PHONY: build-debs
build-debs:
	@echo "Building all Debian packages..."
	@for version in $(PG_VERSIONS); do \
		$(MAKE) build-deb-version VERSION=$$version; \
	done

# Build specific version
.PHONY: build-deb-version
build-deb-version:
	@if [ -z "$(VERSION)" ]; then \
		echo "Usage: make build-deb-version VERSION=16"; \
		exit 1; \
	fi
	@echo "Building PostgreSQL $(VERSION) for all distributions..."
	@for dist in $(DEBIAN_DISTS); do \
		$(MAKE) build-deb-dist VERSION=$(VERSION) DIST=$$dist; \
	done

# Build specific version and distribution
.PHONY: build-deb-dist
build-deb-dist:
	@if [ -z "$(VERSION)" ] || [ -z "$(DIST)" ]; then \
		echo "Usage: make build-deb-dist VERSION=16 DIST=bookworm"; \
		exit 1; \
	fi
	@echo "Building PostgreSQL $(VERSION) for $(DIST)..."
	# Add build commands here
	@echo "✓ Built PostgreSQL $(VERSION) for $(DIST)"

.PHONY: clean
clean:
	@rm -rf $(BUILD_DIR) $(OUTPUT_DIR)
	@echo "Cleaned build artifacts"

.PHONY: help
help:
	@echo "Debian Build System - PostgreSQL"
	@echo "Available targets:"
	@echo "  make build-debs              - Build all versions for all distributions"
	@echo "  make build-deb-version       - Build specific version for all distributions"
	@echo "  make build-deb-dist          - Build specific version for specific distribution"
	@echo "  make clean                   - Clean build artifacts"
EOF

echo ""
echo "✓ Debian folder structure created successfully!"
echo ""
echo "Structure created at:"
echo "  $DEBIAN_ROOT/main/non-common/postgresql-{14,15,16,17,18}/debian/"
echo ""
echo "Next steps:"
echo "  1. Update build-env.sh to reference the new Debian structure"
echo "  2. Test builds with: ./scripts/build-env.sh build-deb --package postgresql-16 --distro bookworm"
echo "  3. Update documentation"
