# Dockerfile.el — Build image for EPEL (AlmaLinux) .rpm packages
#
# Build args:
#   EL_VERSION   — 8 | 9 | 10
#   PG_VERSIONS  — space-separated list, e.g. "14 15 16 17"
#
# Usage:
#   docker build \
#     --build-arg EL_VERSION=9 \
#     --build-arg PG_VERSIONS="14 15 16 17" \
#     -f docker/Dockerfile.el \
#     -t mydbops/pg-build:el9-x86_64 .

ARG EL_VERSION=9
FROM almalinux:${EL_VERSION}

ARG PG_VERSIONS="14 15 16 17"

# Base build toolchain
RUN dnf install -y --allowerasing \
    gcc \
    gcc-c++ \
    make \
    rpm-build \
    rpm-sign \
    rpmlint \
    rpmdevtools \
    redhat-rpm-config \
    epel-release \
    curl \
    ca-certificates \
    gnupg2 \
    python3 \
    python3-pyyaml \
    jq \
    git \
    wget \
    unzip \
    patch \
    autoconf \
    automake \
    libtool \
  && dnf clean all

# PostgreSQL PGDG yum repository
RUN dnf install -y \
    "https://download.postgresql.org/pub/repos/yum/reporpms/EL-$(rpm -E %{rhel})-$(uname -m)/pgdg-redhat-repo-latest.noarch.rpm" \
  && dnf module disable -y postgresql \
  && dnf clean all

# Install dev headers for each PG major version
RUN for v in ${PG_VERSIONS}; do \
      dnf install -y \
        postgresql${v}-devel \
        postgresql${v}-server \
        postgresql${v}-libs \
      || echo "Warning: pg${v} devel not available on EL$(rpm -E %{rhel})"; \
    done \
  && dnf clean all

# rpmmacros for build user
RUN echo "%_topdir /rpmbuild" > /root/.rpmmacros

# AWS CLI v2
RUN curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-$(uname -m).zip" \
      -o /tmp/awscliv2.zip \
  && unzip -q /tmp/awscliv2.zip -d /tmp \
  && /tmp/aws/install \
  && rm -rf /tmp/aws /tmp/awscliv2.zip

WORKDIR /build
