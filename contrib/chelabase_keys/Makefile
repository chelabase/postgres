# contrib/chelabase_keys/Makefile
MODULES = chelabase_keys
PGFILEDESC = "chelabase_keys - primary keys of changed rows, for Chelabase realtime"
REGRESS = keys kinds limits edges encoding stream
ISOLATION = stream_interleave
# UTF8: the plugin refuses SQL_ASCII databases, the default of a cluster made in
# the C locale.
REGRESS_OPTS = --temp-config $(top_srcdir)/contrib/chelabase_keys/logical.conf \
	--encoding=UTF8
ISOLATION_OPTS = --temp-config $(top_srcdir)/contrib/chelabase_keys/logical.conf \
	--encoding=UTF8
NO_INSTALLCHECK = 1
ifdef USE_PGXS
PG_CONFIG = pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)
else
subdir = contrib/chelabase_keys
top_builddir = ../..
include $(top_builddir)/src/Makefile.global
include $(top_srcdir)/contrib/contrib-global.mk
endif
