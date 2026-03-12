#!/usr/bin/env python3
"""
Generate RPM spec file from template.
"""
import argparse
from datetime import datetime

def generate_spec(template_path, output_path, **kwargs):
    with open(template_path, 'r') as f:
        template = f.read()
    
    # Add build date
    kwargs['BUILD_DATE'] = datetime.now().strftime('%a %b %d %Y')
    
    # Replace placeholders
    for key, value in kwargs.items():
        placeholder = f'@{key}@'
        template = template.replace(placeholder, str(value))
    
    with open(output_path, 'w') as f:
        f.write(template)
    
    print(f"Generated spec file: {output_path}")

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--template', required=True)
    parser.add_argument('--output', required=True)
    parser.add_argument('--version', required=True, dest='PG_VERSION')
    parser.add_argument('--major', required=True, dest='PG_MAJOR')
    parser.add_argument('--release', required=True, dest='RELEASE')
    parser.add_argument('--git-commit', required=True, dest='GIT_COMMIT')
    parser.add_argument('--build-id', required=True, dest='BUILD_ID')
    parser.add_argument('--tarball-sha256', default='', dest='TARBALL_SHA256')
    args = parser.parse_args()
    
    generate_spec(**vars(args))
