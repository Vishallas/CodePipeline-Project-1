ARG EL_VERSION=9
FROM almalinux:${EL_VERSION}

ARG PG_VERSIONS="14 15 16 17"

ENV LANG=C.UTF-8 \
    LC_ALL=C.UTF-8

# ------------------------------------------------------------
# Enable repos (EL8/9/10 safe)
# ------------------------------------------------------------
RUN set -eux; \
    dnf install -y dnf-plugins-core epel-release; \
    dnf config-manager --set-enabled crb || true; \
    dnf config-manager --set-enabled powertools || true; \
    dnf clean all

# ------------------------------------------------------------
# Base build tools
# ------------------------------------------------------------
RUN set -eux; \
    dnf install -y --allowerasing \
        gcc \
        gcc-c++ \
        make \
        which \
        sudo \
        git \
        wget \
        curl \
        unzip \
        patch \
        vim-enhanced \
        ca-certificates \
        gnupg2 \
        jq \
        python3 \
        python3-devel \
        python3-pyyaml \
        rpm-build \
        rpm-sign \
        rpmlint \
        rpmdevtools \
        redhat-rpm-config \
        spectool \
        autoconf \
        automake \
        libtool \
        gettext \
        perl \
        perl-devel \
        perl-ExtUtils-Embed \
        perl-ExtUtils-MakeMaker \
        perl-Test-Simple \
        perl-generators \
        docbook-dtds \
        docbook-style-xsl \
        selinux-policy \
    && dnf clean all

# ------------------------------------------------------------
# PostgreSQL build deps
# ------------------------------------------------------------
RUN set -eux; \
    dnf install -y \
        bison \
        flex \
        readline-devel \
        zlib-devel \
        openssl-devel \
        libxml2-devel \
        libxslt-devel \
        pam-devel \
        openldap-devel \
        krb5-devel \
        e2fsprogs-devel \
        libicu-devel \
        libselinux-devel \
        systemd-devel \
        tcl-devel \
        lz4-devel \
        libzstd-devel \
        libuuid-devel \
        libcurl-devel \
    && dnf clean all

# ------------------------------------------------------------
# LLVM / Clang
# ------------------------------------------------------------
RUN dnf install -y llvm-devel clang-devel && dnf clean all

# ------------------------------------------------------------
# PGDG repo
# ------------------------------------------------------------
RUN set -eux; \
    dnf install -y \
      https://download.postgresql.org/pub/repos/yum/reporpms/EL-$(rpm -E %{rhel})-$(uname -m)/pgdg-redhat-repo-latest.noarch.rpm; \
    EL=$(rpm -E %{rhel}); \
    if [ "$EL" = "8" ] || [ "$EL" = "9" ]; then \
        dnf -y module disable postgresql; \
    fi; \
    dnf clean all

# ------------------------------------------------------------
# PostgreSQL versions
# ------------------------------------------------------------
RUN set -eux; \
    for v in ${PG_VERSIONS}; do \
        dnf install -y \
            postgresql${v}-devel \
            postgresql${v}-libs \
            postgresql${v}-server \
        || echo "PG $v not available"; \
    done; \
    dnf clean all

# ------------------------------------------------------------
# rpmbuild dir
# ------------------------------------------------------------
RUN echo "%_topdir /rpmbuild" > /root/.rpmmacros

# ------------------------------------------------------------
# AWS CLI v2
# ------------------------------------------------------------
RUN set -eux; \
    curl -fsSL https://awscli.amazonaws.com/awscli-exe-linux-$(uname -m).zip -o /tmp/aws.zip; \
    unzip -q /tmp/aws.zip -d /tmp; \
    /tmp/aws/install; \
    rm -rf /tmp/aws /tmp/aws.zip

WORKDIR /build