# METADATA.yml — package definition for {{PACKAGE_NAME}}
# Edit all fields marked with TODO before running lint or build.
package:
  name: {{PACKAGE_NAME}}
  short_name: {{PACKAGE_NAME}}
  version: "{{VERSION}}"
  revision: 1
  pg_major: {{PG_MAJOR}}
  description: "{{DESCRIPTION}}"  # TODO: one-line description
  homepage: "https://www.postgresql.org"
  license: PostgreSQL              # TODO: update if different
  source_url: "{{SOURCE_URL}}"    # TODO: set download URL
  source_sha256: ""               # TODO: fill after setting source_url:
  #   curl -sL <source_url> | sha256sum
