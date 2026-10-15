# contrib/chelabase_keys/Makefile
MODULES = chelabase_keys
PGFILEDESC = "chelabase_keys - primary keys of changed rows, for Chelabase realtime"
REGRESS = keys kinds limits
REGRESS_OPTS = --temp-config $(top_srcdir)/contrib/chelabase_keys/logical.conf
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
