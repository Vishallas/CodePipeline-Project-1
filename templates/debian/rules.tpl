#!/usr/bin/make -f

MAJOR_VER = {{PG_MAJOR}}

AUX_MK_DIR = /usr/share/postgresql-common/server

include /usr/share/dpkg/architecture.mk
include /usr/share/dpkg/pkg-info.mk
export DEB_BUILD_MAINT_OPTIONS = hardening=+all
DPKG_EXPORT_BUILDFLAGS = 1
include /usr/share/dpkg/buildflags.mk

PG_CONFIG = /usr/lib/postgresql/$(MAJOR_VER)/bin/pg_config

%:
	dh $@ --with pgcommon --without autoreconf

override_dh_auto_configure:
	./configure \
		--with-pgconfig=$(PG_CONFIG) \
		# TODO: add configure flags

override_dh_auto_install:
	$(MAKE) install DESTDIR=$(CURDIR)/debian/tmp

override_dh_installdocs:
	dh_installdocs README* LICENSE* || true
