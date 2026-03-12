#!/bin/bash
#
# Generate PostgreSQL version-specific packaging files
# This script creates spec files and supporting files for all supported versions
#

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(dirname "${SCRIPT_DIR}")/rpm/redhat/main/non-common"

# Version configurations
# Format: VERSION:RELEASE:PREV_VERSION:MIN_BISON:MIN_FLEX:HAS_LIBURING:HAS_LIBNUMA
declare -A PG_VERSIONS=(
    ["14"]="14.17:1:13:2.3:2.5.35:0:0"
    ["15"]="15.12:1:14:2.3:2.5.35:0:0"
    ["16"]="16.8:1:15:2.3:2.5.35:0:0"
    ["17"]="17.4:1:16:2.3:2.5.35:0:0"
    ["18"]="18.1:1:17:3.0.4:2.6.1:1:1"
)

# Distribution directories
DISTROS=("EL-8" "EL-9" "EL-10" "F-42" "F-43" "SLES-15" "SLES-16")

generate_spec() {
    local VER="$1"
    local CONFIG="${PG_VERSIONS[$VER]}"

    IFS=':' read -r FULL_VER RELEASE PREV_VER MIN_BISON MIN_FLEX HAS_LIBURING HAS_LIBNUMA <<< "$CONFIG"

    local DEST_DIR="${BASE_DIR}/postgresql-${VER}/main"
    local SPEC_FILE="${DEST_DIR}/postgresql-${VER}.spec"

    echo "Generating spec file for PostgreSQL ${VER}..."

    cat > "${SPEC_FILE}" << SPECEOF
# PostgreSQL ${VER} RPM spec file
# Based on mydbops packaging structure
# Maintainable and operational version

# Version information
%global pgmajorversion ${VER}
%global pgpackageversion ${VER}
%global prevmajorversion ${PREV_VER}

# Directory paths
%{!?pginstdir:%global pginstdir /usr/pgsql-%{pgmajorversion}}

# Feature flags - enable/disable at build time
%global beta 0
%{!?enabletaptests:%global enabletaptests 0}
%{!?icu:%global icu 1}
%{!?kerberos:%global kerberos 1}
%{!?ldap:%global ldap 1}
%{!?libnuma:%global libnuma ${HAS_LIBNUMA}}
%{!?liburing:%global liburing ${HAS_LIBURING}}
%{!?llvm:%global llvm 1}
%{!?lz4:%global lz4 1}
%{!?nls:%global nls 1}
%{!?pam:%global pam 1}
%{!?plperl:%global plperl 1}
%{!?plpython3:%global plpython3 1}
%{!?pltcl:%global pltcl 1}
%{!?runselftest:%global runselftest 0}
%{!?selinux:%global selinux 1}
%{!?ssl:%global ssl 1}
%{!?test:%global test 1}
%{!?uuid:%global uuid 1}
%{!?xml:%global xml 1}
%{!?zstd:%global zstd 1}

# SUSE version overrides
%if 0%{?suse_version}
%if 0%{?suse_version} >= 1315
%global systemd_enabled 1
%endif
%endif

# RHEL/Fedora version checks
%if 0%{?rhel} || 0%{?fedora}
%global systemd_enabled 1
%endif

# Disable io_uring on RHEL 8
%if 0%{?rhel} && 0%{?rhel} == 8
%global liburing 0
%endif

# Disable LLVM on certain architectures
%ifarch ppc64 ppc64le s390 s390x armv7hl
%global llvm 0
%endif

# Package information
Name:           postgresql%{pgmajorversion}
Version:        ${FULL_VER}
Release:        ${RELEASE}mydbops%{?dist}
Summary:        PostgreSQL client programs and libraries

License:        PostgreSQL
URL:            https://www.postgresql.org/
Source0:        https://ftp.postgresql.org/pub/source/v%{version}/postgresql-%{version}.tar.bz2

Source4:        postgresql-%{pgmajorversion}-Makefile.regress
Source5:        postgresql-%{pgmajorversion}-pg_config.h
Source6:        postgresql-%{pgmajorversion}-README.rpm-dist
Source7:        postgresql-%{pgmajorversion}-ecpg_config.h
Source9:        postgresql-%{pgmajorversion}-libs.conf
Source10:       postgresql-%{pgmajorversion}-check-db-dir
Source14:       postgresql-%{pgmajorversion}.pam
Source17:       postgresql-%{pgmajorversion}-setup
Source18:       postgresql-%{pgmajorversion}.service
Source19:       postgresql-%{pgmajorversion}-tmpfiles.d
Source20:       postgresql-%{pgmajorversion}-sysusers.conf

Patch1:         postgresql-%{pgmajorversion}-rpm-pgsql.patch
Patch3:         postgresql-%{pgmajorversion}-conf.patch
Patch5:         postgresql-%{pgmajorversion}-var-run-socket.patch
Patch6:         postgresql-%{pgmajorversion}-perl-rpath.patch

BuildRequires:  gcc
BuildRequires:  gcc-c++
BuildRequires:  perl
BuildRequires:  perl(ExtUtils::MakeMaker)
BuildRequires:  bison >= ${MIN_BISON}
BuildRequires:  flex >= ${MIN_FLEX}
BuildRequires:  readline-devel
BuildRequires:  zlib-devel >= 1.0.4
SPECEOF

    # Add libcurl for PG18+
    if [ "${VER}" -ge "18" ]; then
        echo "BuildRequires:  libcurl-devel >= 7.61.0" >> "${SPEC_FILE}"
    fi

    # Continue with conditional build requirements
    cat >> "${SPEC_FILE}" << 'SPECEOF'

%if %icu
BuildRequires:  libicu-devel
%endif

%if %kerberos
BuildRequires:  krb5-devel
BuildRequires:  e2fsprogs-devel
%endif

%if %ldap
%if 0%{?suse_version}
BuildRequires:  openldap2-devel
%else
BuildRequires:  openldap-devel
%endif
%endif

%if %libnuma
%if 0%{?suse_version}
BuildRequires:  libnuma-devel
%else
BuildRequires:  numactl-devel
%endif
%endif

%if %liburing
BuildRequires:  liburing-devel
%endif

%if %llvm
%if 0%{?suse_version} >= 1500 && 0%{?suse_version} < 1600
BuildRequires:  llvm17-devel clang17-devel
%endif
%if 0%{?suse_version} >= 1600
BuildRequires:  llvm19-devel clang19-devel
%endif
%if 0%{?fedora} || 0%{?rhel} >= 8
BuildRequires:  llvm-devel >= 17.0 clang-devel >= 17.0
%endif
%endif

%if %lz4
%if 0%{?suse_version}
BuildRequires:  liblz4-devel
%else
BuildRequires:  lz4-devel
%endif
%endif

%if %nls
BuildRequires:  gettext >= 0.10.35
%endif

%if %pam
BuildRequires:  pam-devel
%endif

%if %plperl
BuildRequires:  perl-devel
BuildRequires:  perl-ExtUtils-Embed
%endif

%if %plpython3
BuildRequires:  python3-devel
%endif

%if %pltcl
BuildRequires:  tcl-devel
%endif

%if %selinux
BuildRequires:  libselinux-devel >= 2.0.93
%endif

%if %ssl
%if 0%{?suse_version} >= 1500
BuildRequires:  libopenssl-3-devel
%else
BuildRequires:  openssl-devel
%endif
%endif

%if %uuid
%if 0%{?suse_version}
BuildRequires:  uuid-devel
%else
BuildRequires:  libuuid-devel
%endif
%endif

%if %xml
BuildRequires:  libxml2-devel
BuildRequires:  libxslt-devel
%endif

%if %zstd
BuildRequires:  libzstd-devel >= 1.4.0
%endif

%if %systemd_enabled
BuildRequires:  systemd systemd-devel
%if 0%{?fedora} >= 43
BuildRequires:  systemd-rpm-macros
%endif
%endif

Requires:       %{name}-libs%{?_isa} = %{version}-%{release}

Requires(post):   %{_sbindir}/update-alternatives
Requires(postun): %{_sbindir}/update-alternatives

Provides:       postgresql

%description
PostgreSQL is an advanced Object-Relational database management system (DBMS).
The base postgresql package contains the client programs that you'll need to
access a PostgreSQL DBMS server, as well as HTML documentation for the whole
system. These client programs can be located on the same machine as the
PostgreSQL server, or on a remote machine that accesses a PostgreSQL server
over a network connection. The PostgreSQL server can be found in the
postgresql%{pgmajorversion}-server sub-package.

%package libs
Summary:        The shared libraries required for any PostgreSQL clients
Provides:       postgresql-libs = %{pgmajorversion}

%description libs
The postgresql%{pgmajorversion}-libs package provides the essential shared
libraries for any PostgreSQL client program or interface.

%package server
Summary:        The programs needed to create and run a PostgreSQL server
Requires:       %{name}%{?_isa} = %{version}-%{release}
Requires:       %{name}-libs%{?_isa} = %{version}-%{release}
Requires(pre):  /usr/sbin/useradd
%if %systemd_enabled
Requires(post): systemd
Requires(preun): systemd
Requires(postun): systemd
%endif
Provides:       postgresql-server

%description server
PostgreSQL is an advanced Object-Relational database management system (DBMS).
The postgresql%{pgmajorversion}-server package contains the programs needed to
create and run a PostgreSQL server.

%package devel
Summary:        PostgreSQL development header files and libraries
Requires:       %{name}%{?_isa} = %{version}-%{release}
Requires:       %{name}-libs%{?_isa} = %{version}-%{release}
Provides:       postgresql-devel

%description devel
The postgresql%{pgmajorversion}-devel package contains the header files and
libraries needed to compile C or C++ applications.

%package contrib
Summary:        Contributed source and binaries distributed with PostgreSQL
Requires:       %{name}%{?_isa} = %{version}-%{release}
Requires:       %{name}-libs%{?_isa} = %{version}-%{release}
Requires:       %{name}-server%{?_isa} = %{version}-%{release}
Provides:       postgresql-contrib

%description contrib
The postgresql%{pgmajorversion}-contrib package contains various extension
modules that are included in the PostgreSQL distribution.

%package docs
Summary:        Extra documentation for PostgreSQL
Provides:       postgresql-docs

%description docs
The postgresql%{pgmajorversion}-docs package includes the documentation.

%if %plperl
%package plperl
Summary:        The Perl procedural language for PostgreSQL
Requires:       %{name}-server%{?_isa} = %{version}-%{release}
Requires:       perl(:MODULE_COMPAT_%(eval "`%{__perl} -V:version`"; echo $version))
Provides:       postgresql-plperl

%description plperl
The postgresql%{pgmajorversion}-plperl package contains the PL/Perl procedural
language.
%endif

%if %plpython3
%package plpython3
Summary:        The Python3 procedural language for PostgreSQL
Requires:       %{name}-server%{?_isa} = %{version}-%{release}
Provides:       postgresql-plpython3

%description plpython3
The postgresql%{pgmajorversion}-plpython3 package contains the PL/Python3
procedural language.
%endif

%if %pltcl
%package pltcl
Summary:        The Tcl procedural language for PostgreSQL
Requires:       %{name}-server%{?_isa} = %{version}-%{release}
Provides:       postgresql-pltcl

%description pltcl
The postgresql%{pgmajorversion}-pltcl package contains the PL/Tcl procedural
language.
%endif

%if %llvm
%package llvmjit
Summary:        Just-in-time compilation support for PostgreSQL
Requires:       %{name}-server%{?_isa} = %{version}-%{release}
Provides:       postgresql-llvmjit

%description llvmjit
The postgresql%{pgmajorversion}-llvmjit package contains support for
just-in-time compilation.
%endif

%if %test
%package test
Summary:        The test suite distributed with PostgreSQL
Requires:       %{name}-server%{?_isa} = %{version}-%{release}
Requires:       %{name}-devel%{?_isa} = %{version}-%{release}
Provides:       postgresql-test

%description test
The postgresql%{pgmajorversion}-test package contains files needed for various
tests.
%endif

%prep
%setup -q -n postgresql-%{version}

%patch -P 1 -p0
%patch -P 3 -p0
%patch -P 5 -p0

%if %plperl
%patch -P 6 -p0
%endif

%build
CFLAGS="${CFLAGS:-%optflags}"
%if %beta
CFLAGS="$CFLAGS -O0 -g"
%endif
export CFLAGS

./configure \
    --enable-rpath \
    --prefix=%{pginstdir} \
    --includedir=%{pginstdir}/include \
    --mandir=%{pginstdir}/share/man \
    --datadir=%{pginstdir}/share \
    --libdir=%{pginstdir}/lib \
    --sysconfdir=/etc/sysconfig/pgsql \
    --docdir=%{pginstdir}/doc \
    --htmldir=%{pginstdir}/doc/html \
%if %beta
    --enable-debug \
    --enable-cassert \
%endif
%if %enabletaptests
    --enable-tap-tests \
%endif
%if %icu
    --with-icu \
%endif
%if %kerberos
    --with-gssapi \
    --with-includes=%{_includedir} \
    --with-libraries=%{_libdir} \
%endif
%if %ldap
    --with-ldap \
%endif
%if %libnuma
    --with-libnuma \
%endif
%if %liburing
    --with-liburing \
%endif
%if %llvm
    --with-llvm \
%endif
%if %lz4
    --with-lz4 \
%endif
%if %nls
    --enable-nls \
%endif
%if %pam
    --with-pam \
%endif
%if %plperl
    --with-perl \
%endif
%if %plpython3
    --with-python \
%endif
%if %pltcl
    --with-tcl \
    --with-tclconfig=%{_libdir} \
%endif
%if %selinux
    --with-selinux \
%endif
%if %ssl
    --with-openssl \
%endif
%if %uuid
    --with-uuid=e2fs \
%endif
%if %xml
    --with-libxml \
    --with-libxslt \
%endif
%if %zstd
    --with-zstd \
%endif
%if %systemd_enabled
    --with-systemd \
%endif
    --with-system-tzdata=/usr/share/zoneinfo

make %{?_smp_mflags} world-bin

%install
make DESTDIR=%{buildroot} install-world-bin

# Install config files
install -d %{buildroot}%{pginstdir}/share/doc
install -m 644 %{SOURCE6} %{buildroot}%{pginstdir}/share/doc/README.rpm-dist

# Install systemd files
%if %systemd_enabled
install -d %{buildroot}%{_unitdir}
install -m 644 %{SOURCE18} %{buildroot}%{_unitdir}/postgresql-%{pgmajorversion}.service
install -d %{buildroot}%{_tmpfilesdir}
install -m 644 %{SOURCE19} %{buildroot}%{_tmpfilesdir}/postgresql-%{pgmajorversion}.conf
install -d %{buildroot}%{_sysusersdir}
install -m 644 %{SOURCE20} %{buildroot}%{_sysusersdir}/postgresql-%{pgmajorversion}.conf
%endif

# Install PAM config
install -d %{buildroot}/etc/pam.d
install -m 644 %{SOURCE14} %{buildroot}/etc/pam.d/postgresql%{pgmajorversion}

# Install setup script
install -d %{buildroot}%{pginstdir}/bin
install -m 755 %{SOURCE17} %{buildroot}%{pginstdir}/bin/postgresql-%{pgmajorversion}-setup
install -m 755 %{SOURCE10} %{buildroot}%{pginstdir}/bin/postgresql-%{pgmajorversion}-check-db-dir

# Install ld.so.conf.d file
install -d %{buildroot}/etc/ld.so.conf.d
install -m 644 %{SOURCE9} %{buildroot}/etc/ld.so.conf.d/postgresql-%{pgmajorversion}-libs.conf

# Create data directories
install -d %{buildroot}/var/lib/pgsql/%{pgmajorversion}/data
install -d %{buildroot}/var/lib/pgsql/%{pgmajorversion}/backups
install -d %{buildroot}/var/run/postgresql

# Create sysconfig directory
install -d %{buildroot}/etc/sysconfig/pgsql/%{pgmajorversion}

# Install test files if enabled
%if %test
install -d %{buildroot}%{pginstdir}/lib/test
cp -a src/test/regress %{buildroot}%{pginstdir}/lib/test/
install -m 644 %{SOURCE4} %{buildroot}%{pginstdir}/lib/test/Makefile
%endif

%post libs
/sbin/ldconfig

%postun libs
/sbin/ldconfig

%pre server
/usr/sbin/groupadd -g 26 -o -r postgres >/dev/null 2>&1 || :
/usr/sbin/useradd -M -g postgres -o -r -d /var/lib/pgsql -s /bin/bash \
    -c "PostgreSQL Server" -u 26 postgres >/dev/null 2>&1 || :

%post server
%if %systemd_enabled
%systemd_post postgresql-%{pgmajorversion}.service
%endif
/sbin/ldconfig

# Create .bash_profile for postgres user
cat > /var/lib/pgsql/.bash_profile << 'EOF'
[ -f /etc/profile ] && source /etc/profile
PGDATA=/var/lib/pgsql/%{pgmajorversion}/data
export PGDATA
PATH=%{pginstdir}/bin:$PATH
export PATH
EOF
chown postgres:postgres /var/lib/pgsql/.bash_profile
chmod 700 /var/lib/pgsql/.bash_profile

%preun server
%if %systemd_enabled
%systemd_preun postgresql-%{pgmajorversion}.service
%endif

%postun server
%if %systemd_enabled
%systemd_postun_with_restart postgresql-%{pgmajorversion}.service
%endif
/sbin/ldconfig

%post
%{_sbindir}/update-alternatives --install %{_bindir}/psql pgsql-psql %{pginstdir}/bin/psql %{pgmajorversion}0
%{_sbindir}/update-alternatives --install %{_bindir}/pg_dump pgsql-pg_dump %{pginstdir}/bin/pg_dump %{pgmajorversion}0

%postun
if [ $1 -eq 0 ] ; then
    %{_sbindir}/update-alternatives --remove pgsql-psql %{pginstdir}/bin/psql
    %{_sbindir}/update-alternatives --remove pgsql-pg_dump %{pginstdir}/bin/pg_dump
fi

%files
%defattr(-,root,root)
%doc COPYRIGHT
%{pginstdir}/bin/clusterdb
%{pginstdir}/bin/createdb
%{pginstdir}/bin/createuser
%{pginstdir}/bin/dropdb
%{pginstdir}/bin/dropuser
%{pginstdir}/bin/pg_basebackup
%{pginstdir}/bin/pg_dump
%{pginstdir}/bin/pg_dumpall
%{pginstdir}/bin/pg_isready
%{pginstdir}/bin/pg_receivewal
%{pginstdir}/bin/pg_restore
%{pginstdir}/bin/pg_verifybackup
%{pginstdir}/bin/psql
%{pginstdir}/bin/reindexdb
%{pginstdir}/bin/vacuumdb
%{pginstdir}/share/man/man1/clusterdb.*
%{pginstdir}/share/man/man1/createdb.*
%{pginstdir}/share/man/man1/createuser.*
%{pginstdir}/share/man/man1/dropdb.*
%{pginstdir}/share/man/man1/dropuser.*
%{pginstdir}/share/man/man1/pg_basebackup.*
%{pginstdir}/share/man/man1/pg_dump.*
%{pginstdir}/share/man/man1/pg_dumpall.*
%{pginstdir}/share/man/man1/pg_isready.*
%{pginstdir}/share/man/man1/pg_receivewal.*
%{pginstdir}/share/man/man1/pg_restore.*
%{pginstdir}/share/man/man1/pg_verifybackup.*
%{pginstdir}/share/man/man1/psql.*
%{pginstdir}/share/man/man1/reindexdb.*
%{pginstdir}/share/man/man1/vacuumdb.*
%{pginstdir}/share/man/man7/*

%files libs
%defattr(-,root,root)
%{pginstdir}/lib/libpq.so.*
%{pginstdir}/lib/libecpg.so.*
%{pginstdir}/lib/libecpg_compat.so.*
%{pginstdir}/lib/libpgtypes.so.*
%config(noreplace) /etc/ld.so.conf.d/postgresql-%{pgmajorversion}-libs.conf

%files server
%defattr(-,root,root)
%{pginstdir}/bin/initdb
%{pginstdir}/bin/pg_controldata
%{pginstdir}/bin/pg_ctl
%{pginstdir}/bin/pg_resetwal
%{pginstdir}/bin/pg_rewind
%{pginstdir}/bin/pg_upgrade
%{pginstdir}/bin/postgres
%{pginstdir}/bin/postmaster
%{pginstdir}/bin/postgresql-%{pgmajorversion}-check-db-dir
%{pginstdir}/bin/postgresql-%{pgmajorversion}-setup
%{pginstdir}/share/*.sql
%{pginstdir}/share/*.sample
%{pginstdir}/share/errcodes.txt
%{pginstdir}/share/postgres.bki
%{pginstdir}/share/information_schema.sql
%{pginstdir}/share/snowball_create.sql
%{pginstdir}/share/sql_features.txt
%{pginstdir}/share/system_constraints.sql
%{pginstdir}/share/system_functions.sql
%{pginstdir}/share/system_views.sql
%{pginstdir}/share/timezonesets/
%{pginstdir}/share/tsearch_data/
%{pginstdir}/share/man/man1/initdb.*
%{pginstdir}/share/man/man1/pg_controldata.*
%{pginstdir}/share/man/man1/pg_ctl.*
%{pginstdir}/share/man/man1/pg_resetwal.*
%{pginstdir}/share/man/man1/pg_rewind.*
%{pginstdir}/share/man/man1/pg_upgrade.*
%{pginstdir}/share/man/man1/postgres.*
%{pginstdir}/share/man/man1/postmaster.*
%{pginstdir}/lib/dict_int.so
%{pginstdir}/lib/dict_snowball.so
%{pginstdir}/lib/dict_xsyn.so
%{pginstdir}/lib/euc2004_sjis2004.so
%{pginstdir}/lib/pg_prewarm.so
%{pginstdir}/lib/pgoutput.so
%{pginstdir}/lib/plpgsql.so
%dir %{pginstdir}/lib
%dir %{pginstdir}/share
%dir %{pginstdir}/share/extension
%{pginstdir}/share/extension/plpgsql*
%attr(700,postgres,postgres) %dir /var/lib/pgsql
%attr(700,postgres,postgres) %dir /var/lib/pgsql/%{pgmajorversion}
%attr(700,postgres,postgres) %dir /var/lib/pgsql/%{pgmajorversion}/data
%attr(700,postgres,postgres) %dir /var/lib/pgsql/%{pgmajorversion}/backups
%dir /var/run/postgresql
%{_tmpfilesdir}/postgresql-%{pgmajorversion}.conf
%{_sysusersdir}/postgresql-%{pgmajorversion}.conf
%{_unitdir}/postgresql-%{pgmajorversion}.service
%config(noreplace) /etc/pam.d/postgresql%{pgmajorversion}
%dir /etc/sysconfig/pgsql
%dir /etc/sysconfig/pgsql/%{pgmajorversion}
%{pginstdir}/share/doc/README.rpm-dist

%files devel
%defattr(-,root,root)
%{pginstdir}/bin/ecpg
%{pginstdir}/bin/pg_config
%{pginstdir}/include/*
%{pginstdir}/lib/libpq.so
%{pginstdir}/lib/libecpg.so
%{pginstdir}/lib/libecpg_compat.so
%{pginstdir}/lib/libpgtypes.so
%{pginstdir}/lib/libpq.a
%{pginstdir}/lib/libecpg.a
%{pginstdir}/lib/libecpg_compat.a
%{pginstdir}/lib/libpgtypes.a
%{pginstdir}/lib/libpgcommon.a
%{pginstdir}/lib/libpgfeutils.a
%{pginstdir}/lib/libpgport.a
%{pginstdir}/lib/pgxs/
%{pginstdir}/lib/pkgconfig/
%{pginstdir}/share/man/man1/ecpg.*
%{pginstdir}/share/man/man1/pg_config.*
%{pginstdir}/share/man/man3/*

%files contrib
%defattr(-,root,root)
%{pginstdir}/bin/oid2name
%{pginstdir}/bin/pg_amcheck
%{pginstdir}/bin/pgbench
%{pginstdir}/bin/vacuumlo
%{pginstdir}/lib/_int.so
%{pginstdir}/lib/adminpack.so
%{pginstdir}/lib/amcheck.so
%{pginstdir}/lib/auth_delay.so
%{pginstdir}/lib/auto_explain.so
%{pginstdir}/lib/autoinc.so
%{pginstdir}/lib/basic_archive.so
%{pginstdir}/lib/bloom.so
%{pginstdir}/lib/btree_gin.so
%{pginstdir}/lib/btree_gist.so
%{pginstdir}/lib/citext.so
%{pginstdir}/lib/cube.so
%{pginstdir}/lib/dblink.so
%{pginstdir}/lib/earthdistance.so
%{pginstdir}/lib/file_fdw.so
%{pginstdir}/lib/fuzzystrmatch.so
%{pginstdir}/lib/hstore.so
%{pginstdir}/lib/insert_username.so
%{pginstdir}/lib/intagg.so
%{pginstdir}/lib/intarray.so
%{pginstdir}/lib/isn.so
%{pginstdir}/lib/lo.so
%{pginstdir}/lib/ltree.so
%{pginstdir}/lib/moddatetime.so
%{pginstdir}/lib/old_snapshot.so
%{pginstdir}/lib/pageinspect.so
%{pginstdir}/lib/passwordcheck.so
%{pginstdir}/lib/pg_buffercache.so
%{pginstdir}/lib/pg_freespacemap.so
%{pginstdir}/lib/pg_stat_statements.so
%{pginstdir}/lib/pg_surgery.so
%{pginstdir}/lib/pg_trgm.so
%{pginstdir}/lib/pg_visibility.so
%{pginstdir}/lib/pg_walinspect.so
%{pginstdir}/lib/pgcrypto.so
%{pginstdir}/lib/pgrowlocks.so
%{pginstdir}/lib/pgstattuple.so
%{pginstdir}/lib/postgres_fdw.so
%{pginstdir}/lib/refint.so
%{pginstdir}/lib/seg.so
%{pginstdir}/lib/sslinfo.so
%{pginstdir}/lib/tablefunc.so
%{pginstdir}/lib/tcn.so
%{pginstdir}/lib/tsm_system_rows.so
%{pginstdir}/lib/tsm_system_time.so
%{pginstdir}/lib/unaccent.so
%if %uuid
%{pginstdir}/lib/uuid-ossp.so
%{pginstdir}/share/extension/uuid-ossp*
%endif
%if %xml
%{pginstdir}/lib/xml2.so
%{pginstdir}/share/extension/xml2*
%endif
%{pginstdir}/share/extension/*
%exclude %{pginstdir}/share/extension/plpgsql*
%if %uuid
%exclude %{pginstdir}/share/extension/uuid-ossp*
%endif
%if %xml
%exclude %{pginstdir}/share/extension/xml2*
%endif
%{pginstdir}/share/man/man1/oid2name.*
%{pginstdir}/share/man/man1/pg_amcheck.*
%{pginstdir}/share/man/man1/pgbench.*
%{pginstdir}/share/man/man1/vacuumlo.*

%files docs
%defattr(-,root,root)
%doc COPYRIGHT
%{pginstdir}/doc/*

%if %plperl
%files plperl
%defattr(-,root,root)
%{pginstdir}/lib/bool_plperl.so
%{pginstdir}/lib/hstore_plperl.so
%{pginstdir}/lib/jsonb_plperl.so
%{pginstdir}/lib/plperl.so
%{pginstdir}/share/extension/plperl*
%{pginstdir}/share/extension/bool_plperl*
%{pginstdir}/share/extension/hstore_plperl*
%{pginstdir}/share/extension/jsonb_plperl*
%endif

%if %plpython3
%files plpython3
%defattr(-,root,root)
%{pginstdir}/lib/hstore_plpython3.so
%{pginstdir}/lib/jsonb_plpython3.so
%{pginstdir}/lib/ltree_plpython3.so
%{pginstdir}/lib/plpython3.so
%{pginstdir}/share/extension/plpython3u*
%{pginstdir}/share/extension/hstore_plpython3u*
%{pginstdir}/share/extension/jsonb_plpython3u*
%{pginstdir}/share/extension/ltree_plpython3u*
%endif

%if %pltcl
%files pltcl
%defattr(-,root,root)
%{pginstdir}/lib/pltcl.so
%{pginstdir}/share/extension/pltcl*
%endif

%if %llvm
%files llvmjit
%defattr(-,root,root)
%{pginstdir}/lib/bitcode/
%{pginstdir}/lib/llvmjit.so
%{pginstdir}/lib/llvmjit_types.bc
%endif

%if %test
%files test
%defattr(-,postgres,postgres)
%{pginstdir}/lib/test/
%endif

%changelog
SPECEOF

    # Add changelog entry
    local TODAY=$(date +"%a %b %d %Y")
    echo "* ${TODAY} PostgreSQL Packaging Team <packaging@example.com> - ${FULL_VER}-${RELEASE}mydbops" >> "${SPEC_FILE}"
    echo "- Initial package for PostgreSQL ${FULL_VER}" >> "${SPEC_FILE}"
}

generate_supporting_files() {
    local VER="$1"
    local CONFIG="${PG_VERSIONS[$VER]}"

    IFS=':' read -r FULL_VER RELEASE PREV_VER MIN_BISON MIN_FLEX HAS_LIBURING HAS_LIBNUMA <<< "$CONFIG"

    local DEST_DIR="${BASE_DIR}/postgresql-${VER}/main"

    echo "Generating supporting files for PostgreSQL ${VER}..."

    # Service file
    cat > "${DEST_DIR}/postgresql-${VER}.service" << SERVICEEOF
[Unit]
Description=PostgreSQL ${VER} database server
Documentation=https://www.postgresql.org/docs/${VER}/static/
After=syslog.target
After=network-online.target
Wants=network-online.target

[Service]
Type=notify
User=postgres
Group=postgres
Environment=PGDATA=/var/lib/pgsql/${VER}/data/
OOMScoreAdjust=-1000
Environment=PG_OOM_ADJUST_FILE=/proc/self/oom_score_adj
Environment=PG_OOM_ADJUST_VALUE=0
ExecStartPre=/usr/pgsql-${VER}/bin/postgresql-${VER}-check-db-dir \${PGDATA}
ExecStart=/usr/pgsql-${VER}/bin/postgres -D \${PGDATA}
ExecReload=/bin/kill -HUP \$MAINPID
KillMode=mixed
KillSignal=SIGINT
Restart=on-failure
TimeoutSec=0
TimeoutStartSec=0
TimeoutStopSec=1h

[Install]
WantedBy=multi-user.target
SERVICEEOF

    # Setup script
    cat > "${DEST_DIR}/postgresql-${VER}-setup" << 'SETUPEOF'
#!/bin/bash
PGSETUP_VERSION=1.0
SETUPEOF
    sed -i "s/PGVERSION=.*/PGVERSION=${VER}/" "${DEST_DIR}/postgresql-${VER}-setup"
    sed -i "s/PGMAJORVERSION=.*/PGMAJORVERSION=${VER}/" "${DEST_DIR}/postgresql-${VER}-setup"
    sed -i "s/PREVMAJORVERSION=.*/PREVMAJORVERSION=${PREV_VER}/" "${DEST_DIR}/postgresql-${VER}-setup"

    # Copy full setup script from PG18 and modify
    cp "${BASE_DIR}/postgresql-18/main/postgresql-18-setup" "${DEST_DIR}/postgresql-${VER}-setup"
    sed -i "s/PGVERSION=18/PGVERSION=${VER}/g" "${DEST_DIR}/postgresql-${VER}-setup"
    sed -i "s/PGMAJORVERSION=18/PGMAJORVERSION=${VER}/g" "${DEST_DIR}/postgresql-${VER}-setup"
    sed -i "s/PREVMAJORVERSION=17/PREVMAJORVERSION=${PREV_VER}/g" "${DEST_DIR}/postgresql-${VER}-setup"
    sed -i "s/pgsql-18/pgsql-${VER}/g" "${DEST_DIR}/postgresql-${VER}-setup"
    sed -i "s/postgresql-18/postgresql-${VER}/g" "${DEST_DIR}/postgresql-${VER}-setup"

    # Check-db-dir script
    cp "${BASE_DIR}/postgresql-18/main/postgresql-18-check-db-dir" "${DEST_DIR}/postgresql-${VER}-check-db-dir"
    sed -i "s/pgsql-18/pgsql-${VER}/g" "${DEST_DIR}/postgresql-${VER}-check-db-dir"
    sed -i "s/postgresql-18/postgresql-${VER}/g" "${DEST_DIR}/postgresql-${VER}-check-db-dir"
    sed -i "s/\"18\"/\"${VER}\"/g" "${DEST_DIR}/postgresql-${VER}-check-db-dir"

    # PAM file
    cp "${BASE_DIR}/postgresql-18/main/postgresql-18.pam" "${DEST_DIR}/postgresql-${VER}.pam"

    # tmpfiles.d
    cat > "${DEST_DIR}/postgresql-${VER}-tmpfiles.d" << TMPEOF
d /run/postgresql 0755 postgres postgres -
TMPEOF

    # sysusers.conf
    cat > "${DEST_DIR}/postgresql-${VER}-sysusers.conf" << SYSEOF
u postgres 26 "PostgreSQL Server" /var/lib/pgsql /bin/bash
SYSEOF

    # libs.conf
    cat > "${DEST_DIR}/postgresql-${VER}-libs.conf" << LIBSEOF
/usr/pgsql-${VER}/lib
LIBSEOF

    # README.rpm-dist
    cp "${BASE_DIR}/postgresql-18/main/postgresql-18-README.rpm-dist" "${DEST_DIR}/postgresql-${VER}-README.rpm-dist"
    sed -i "s/pgsql-18/pgsql-${VER}/g" "${DEST_DIR}/postgresql-${VER}-README.rpm-dist"
    sed -i "s/postgresql-18/postgresql-${VER}/g" "${DEST_DIR}/postgresql-${VER}-README.rpm-dist"
    sed -i "s/postgresql18/postgresql${VER}/g" "${DEST_DIR}/postgresql-${VER}-README.rpm-dist"
    sed -i "s|/18/|/${VER}/|g" "${DEST_DIR}/postgresql-${VER}-README.rpm-dist"

    # Patches
    for patch in rpm-pgsql conf var-run-socket perl-rpath; do
        cp "${BASE_DIR}/postgresql-18/main/postgresql-18-${patch}.patch" \
           "${DEST_DIR}/postgresql-${VER}-${patch}.patch"
    done

    # Additional source files
    cp "${BASE_DIR}/postgresql-18/main/postgresql-18-Makefile.regress" \
       "${DEST_DIR}/postgresql-${VER}-Makefile.regress"
    sed -i "s/pgsql-18/pgsql-${VER}/g" "${DEST_DIR}/postgresql-${VER}-Makefile.regress"

    cp "${BASE_DIR}/postgresql-18/main/postgresql-18-pg_config.h" \
       "${DEST_DIR}/postgresql-${VER}-pg_config.h"

    cp "${BASE_DIR}/postgresql-18/main/postgresql-18-ecpg_config.h" \
       "${DEST_DIR}/postgresql-${VER}-ecpg_config.h"

    # Makefile
    cat > "${DEST_DIR}/Makefile" << MAKEEOF
#################################
# RPM-specific Makefile         #
# PostgreSQL ${VER} packaging   #
#################################

ARCH=\`rpm --eval "%{_arch}"\`
DIR=\`pwd\`
SPECFILE="postgresql-${VER}.spec"

include ../../../../global/Makefile.global
MAKEEOF

    chmod +x "${DEST_DIR}/postgresql-${VER}-setup"
    chmod +x "${DEST_DIR}/postgresql-${VER}-check-db-dir"
}

create_distro_symlinks() {
    local VER="$1"
    local PKG_DIR="${BASE_DIR}/postgresql-${VER}"

    echo "Creating distribution symlinks for PostgreSQL ${VER}..."

    for DISTRO in "${DISTROS[@]}"; do
        local DISTRO_DIR="${PKG_DIR}/${DISTRO}"
        mkdir -p "${DISTRO_DIR}"

        # Create symlinks to main files
        for file in "${PKG_DIR}/main/"*; do
            local filename=$(basename "$file")
            if [ -f "$file" ]; then
                ln -sf "../main/${filename}" "${DISTRO_DIR}/${filename}"
            fi
        done

        # Copy Makefile (not symlink, as it may need distro-specific changes)
        cp "${PKG_DIR}/main/Makefile" "${DISTRO_DIR}/Makefile"
    done
}

# Main execution
echo "=== PostgreSQL Version Generator ==="
echo ""

for ver in 14 15 16 17; do
    echo "Processing PostgreSQL ${ver}..."
    generate_spec "${ver}"
    generate_supporting_files "${ver}"
    create_distro_symlinks "${ver}"
    echo ""
done

# Also create symlinks for PG18
create_distro_symlinks 18

echo "=== Generation Complete ==="
