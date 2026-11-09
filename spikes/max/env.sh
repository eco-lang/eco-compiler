# Source this before running anything that loads libmax.so:  . spikes/max/env.sh
#
# libmax finds its built-in kernel packages only through these variables (MAX's Python wrapper sets
# them itself); without them every compile fails with "failed to resolve built-in kernel package
# paths". MAX_VENV is the venv setup.sh made.
_here=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
: "${MAX_VENV:=$_here/.venv}"
MAX_SITE=$(echo "$MAX_VENV"/lib/python3*/site-packages)
export MAX_VENV MAX_SITE
export MODULAR_MAX_PACKAGE_ROOT="$MAX_SITE/modular"
export MODULAR_MOJO_MAX_PACKAGE_ROOT="$MAX_SITE/modular"
export MODULAR_MOJO_MAX_IMPORT_PATH="$MAX_SITE/modular/lib/mojo"
# MAX's documented telemetry opt-out; without it every run makes an HTTPS call to Modular.
export MODULAR_TELEMETRY_ENABLED=0
unset _here
