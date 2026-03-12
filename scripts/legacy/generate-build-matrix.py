#!/usr/bin/env python3
"""
Generate build matrix from configuration files.
"""
import yaml
import json
import argparse
import sys

def load_yaml(filepath):
    with open(filepath, 'r') as f:
        return yaml.safe_load(f)

def generate_matrix(versions_file, targets_file):
    versions = load_yaml(versions_file)
    targets = load_yaml(targets_file)
    
    rpm_matrix = []
    deb_matrix = []
    
    # Generate RPM combinations
    for version in versions['postgresql_versions']:
        if version['support_status'] != 'active':
            continue
        for target in targets['rpm_targets']:
            if not target.get('enabled', True):
                continue
            rpm_matrix.append({
                'pg_major': version['major'],
                'pg_version': version['version'],
                'tarball_sha256': version['tarball_sha256'],
                'os': target['os'],
                'dist': target['dist'],
                'arch': target['arch'],
                'builder_image': target['builder_image'],
                'mock_config': target['mock_config']
            })
    
    # Generate DEB combinations
    for version in versions['postgresql_versions']:
        if version['support_status'] != 'active':
            continue
        for target in targets['deb_targets']:
            if not target.get('enabled', True):
                continue
            deb_matrix.append({
                'pg_major': version['major'],
                'pg_version': version['version'],
                'tarball_sha256': version['tarball_sha256'],
                'dist': target['dist'],
                'arch': target['arch'],
                'builder_image': target['builder_image']
            })
    
    return {
        'rpm': rpm_matrix,
        'deb': deb_matrix
    }

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--versions', required=True)
    parser.add_argument('--targets', required=True)
    args = parser.parse_args()
    
    matrix = generate_matrix(args.versions, args.targets)
    print(json.dumps(matrix))
