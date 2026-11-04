#!/bin/sh
# HttpServerService.cpp holds only worker-side code (HttpSrv::listenOn runs on a SysWorkPool worker), and
# std::strerror is not required to be thread-safe. listenOn returns the errno and the eco thread formats the text,
# so this file calls no strerror at all. Exit 0 = no strerror call in the file, 1 = strerror called there.
root=${1:-.}
f="$root/system-kernel-cpp/src/eco-system/HttpServer/HttpServerService.cpp"
[ -f "$f" ] || { echo "no $f"; exit 2; }
# Calls only: skip comment lines.
if grep -nE '(^|[^_[:alnum:]])strerror[[:space:]]*\(' "$f" | grep -vE '^[0-9]+:[[:space:]]*//'; then
    echo "strerror called in worker-side code (listenOn)"
    exit 1
fi
exit 0
