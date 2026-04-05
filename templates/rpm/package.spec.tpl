%global pgmajorversion {{PG_MAJOR}}
%global pgbaseinstdir   /usr/pgsql-%{pgmajorversion}
%global sname           {{SHORT_NAME}}

Name:           {{PACKAGE_NAME}}
Version:        {{VERSION}}
Release:        {{REVISION}}PGDG%{?dist}
Summary:        {{DESCRIPTION}}
License:        PostgreSQL
URL:            {{SOURCE_URL}}
Source0:        {{SOURCE_URL}}

BuildRequires:  postgresql%{pgmajorversion}-devel
BuildRequires:  gcc
Requires:       postgresql%{pgmajorversion}

%description
{{DESCRIPTION}}

TODO: Add detailed package description.

%prep
%setup -q -n %{sname}-%{version}

%build
%configure \
    --with-pgconfig=%{pgbaseinstdir}/bin/pg_config
# TODO: add configure flags
%make_build

%install
%make_install DESTDIR=%{buildroot}

%files
%{pgbaseinstdir}/lib/%{sname}.so
%{pgbaseinstdir}/share/extension/%{sname}*.sql
%{pgbaseinstdir}/share/extension/%{sname}*.control

%changelog
* {{CHANGELOG_DATE}} Pg-platform <ops@pg-platform.com> - {{VERSION}}-{{REVISION}}
- Initial packaging of {{PACKAGE_NAME}} {{VERSION}}.
