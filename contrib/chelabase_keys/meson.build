# Copyright (c) 2026, Chelabase

chelabase_keys_sources = files(
  'chelabase_keys.c',
)

if host_system == 'windows'
  chelabase_keys_sources += rc_lib_gen.process(win32ver_rc, extra_args: [
    '--NAME', 'chelabase_keys',
    '--FILEDESC', 'chelabase_keys - primary keys of changed rows, for Chelabase realtime',])
endif

chelabase_keys = shared_module('chelabase_keys',
  chelabase_keys_sources,
  kwargs: contrib_mod_args,
)
contrib_targets += chelabase_keys

tests += {
  'name': 'chelabase_keys',
  'sd': meson.current_source_dir(),
  'bd': meson.current_build_dir(),
  'regress': {
    'sql': [
      'keys',
      'kinds',
      'limits',
      'edges',
      'encoding',
      'stream',
    ],
    'regress_args': [
      '--temp-config', files('logical.conf'),
      # the plugin refuses SQL_ASCII databases (a C-locale cluster's default)
      '--encoding=UTF8',
    ],
    # These tests need "wal_level = logical".
    'runningcheck': false,
  },
  'isolation': {
    'specs': [
      'stream_interleave',
    ],
    'regress_args': [
      '--temp-config', files('logical.conf'),
      '--encoding=UTF8',
    ],
    # see above
    'runningcheck': false,
  },
}
