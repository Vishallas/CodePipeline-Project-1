# build.yml — build target configuration for {{PACKAGE_NAME}}
# Set enabled: true for targets you want to build.
# Start with one target for testing; enable others once the build passes.
targets:
  - os: ubuntu
    release: 20
    arch: [amd64]
    enabled: false

  - os: ubuntu
    release: 22
    arch: [amd64, arm64]
    enabled: false

  - os: ubuntu
    release: 24
    arch: [amd64, arm64]
    enabled: false

  - os: epel
    release: 8
    arch: [x86_64, aarch64]
    enabled: false

  - os: epel
    release: 9
    arch: [x86_64, aarch64]
    enabled: false

  - os: epel
    release: 10
    arch: [x86_64]
    enabled: false

  - os: fedora
    release: 42
    arch: [x86_64]
    enabled: false

  - os: fedora
    release: 43
    arch: [x86_64]
    enabled: false
