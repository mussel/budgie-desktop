# Control the order and relation between the subcomponents in Budgie

# Library components
subdir('plugin')
subdir('config')
subdir('libsession')

# Needed for daemon + applets
subdir('appsys')

subdir('imports')
subdir('theme')
subdir('lib')
subdir('raven')

# Executable components
subdir('daemon')

if with_polkit == true
    subdir('polkit')
endif

subdir('rundialog')
subdir('wm')
subdir('panel')

# Now build applets
subdir('applets')

# Finish up by doing the session
subdir('session')

# gschemas
install_data(
  'com.solus-project.budgie.gschema.xml',
  install_dir: join_paths(datadir, 'glib-2.0', 'schemas')
)
