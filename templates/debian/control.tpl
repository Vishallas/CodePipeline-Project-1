Source: {{PACKAGE_NAME}}
Section: database
Priority: optional
Maintainer: Pg-platform <ops@pg-platform.com>
Build-Depends:
 debhelper-compat (= 13),
 postgresql-server-dev-{{PG_MAJOR}},
 # TODO: add build dependencies
Standards-Version: 4.5.0
Rules-Requires-Root: no
Homepage: https://www.postgresql.org

Package: {{PACKAGE_NAME}}
Architecture: any
Depends:
 postgresql-{{PG_MAJOR}},
 ${shlibs:Depends},
 ${misc:Depends}
Description: {{DESCRIPTION}}
 TODO: long description for {{PACKAGE_NAME}}.
