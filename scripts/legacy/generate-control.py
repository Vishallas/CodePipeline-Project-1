#!/usr/bin/env python3
"""
Generate Debian package files from templates.

Supports replacing template variables:
  @PG_MAJOR@        - PostgreSQL major version (e.g., 16)
  @PG_VERSION@      - Full PostgreSQL version (e.g., 16.8)
  @PG_RELEASE@      - Package release number (e.g., 1)
  @DIST_CODENAME@   - Debian/Ubuntu codename (e.g., bookworm, jammy)
  @BUILD_ID@        - Build identifier
  @GIT_COMMIT@      - Git commit hash
  @BUILD_DATE@      - Build date (RFC 2822 format)
"""
import argparse
import os
import sys
from datetime import datetime, timezone
import subprocess

def get_git_commit():
    """Get current git commit hash."""
    try:
        return subprocess.check_output(
            ['git', 'rev-parse', 'HEAD'],
            stderr=subprocess.DEVNULL,
            text=True
        ).strip()[:7]
    except Exception:
        return "unknown"

def get_build_date():
    """Get current date in RFC 2822 format."""
    # RFC 2822 format: Thu, 10 Feb 2026 15:30:00 +0000
    return datetime.now(timezone.utc).strftime('%a, %d %b %Y %H:%M:%S %z')

def generate_from_template(template_path, output_path, variables):
    """Generate a file from template by replacing variables."""
    try:
        with open(template_path, 'r') as f:
            content = f.read()

        # Replace all template variables
        for var_name, var_value in variables.items():
            placeholder = f'@{var_name}@'
            content = content.replace(placeholder, str(var_value))

        # Write output file
        with open(output_path, 'w') as f:
            f.write(content)

        # Preserve executable bit if input was executable
        if os.access(template_path, os.X_OK):
            os.chmod(output_path, 0o755)

        return True
    except Exception as e:
        print(f"ERROR: Failed to generate {output_path}: {e}", file=sys.stderr)
        return False

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description='Generate Debian files from templates')
    parser.add_argument('--template', required=True, help='Template file path')
    parser.add_argument('--output', required=True, help='Output file path')
    parser.add_argument('--major', required=True, type=int, help='PostgreSQL major version')
    parser.add_argument('--full', default=None, help='PostgreSQL full version')
    parser.add_argument('--release', default='1', help='Package release number')
    parser.add_argument('--dist', default='bookworm', help='Debian/Ubuntu distribution codename')
    parser.add_argument('--build-id', default=None, help='Build identifier')
    parser.add_argument('--git-commit', action='store_true', help='Auto-detect git commit')
    args = parser.parse_args()

    # Build variables dictionary
    variables = {
        'PG_MAJOR': args.major,
        'PG_VERSION': args.full or f"{args.major}.0",
        'PG_RELEASE': args.release,
        'DIST_CODENAME': args.dist,
        'BUILD_ID': args.build_id or f"build-{datetime.now().strftime('%Y%m%d-%H%M%S')}",
        'GIT_COMMIT': get_git_commit() if args.git_commit else 'unknown',
        'BUILD_DATE': get_build_date(),
    }

    success = generate_from_template(args.template, args.output, variables)

    if success:
        print(f"Generated: {os.path.basename(args.output)}")
        sys.exit(0)
    else:
        sys.exit(1)
