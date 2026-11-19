#!/bin/sh
# Only the kernel ABI may use C names (REP_ABI_001). A C++ helper declared inside an `extern "C"`
# block is exported under its bare, unmangled name into the global symbol namespace of every program.
#
# Runs `nm -A -g --defined-only` over the built kernel archives (elm-kernel-cpp ElmKernel_*, eco-kernel-cpp
# EcoKernel_*, system-kernel-cpp EcoSystem_*) and, for the members compiled from our own C++ (`*.cpp.o`;
# vendored C such as llhttp/nghttp2 is `*.c.o`), reports every defined global function symbol that is neither
# C++-mangled (`_Z...`) nor in the export namespace: the prefixes `Elm_Kernel_`, `Eco_Kernel_`, `EcoSystem_`,
# `Eco_Http_`, `Eco_Runtime_`, `Eco_System_`, `eco_`, `elm_` (runtime ABI names), plus the allowlisted names
# `ecoSystemSignalHandler` (a deliberate C signal handler) and `__clang_call_terminate`.
#
# Build directory: $ECO_BUILD_DIR, else <repo-root>/build, so run it after the build.
# Exit 0 = clean, 1 = found, 2 = no archives (build first).
root=${1:-.}
build=${ECO_BUILD_DIR:-$root/build}
archives=$(ls "$build"/elm-kernel-cpp/libElmKernel_*.a "$build"/eco-kernel-cpp/libEcoKernel_*.a \
               "$build"/system-kernel-cpp/libEcoSystem_*.a 2>/dev/null)
[ -n "$archives" ] || { echo "no kernel archives under $build (build the kernels first)"; exit 2; }
found=0
for a in $archives; do
    bad=$(nm -A -g --defined-only "$a" 2>/dev/null | awk '
        ($(NF-1) == "T" || $(NF-1) == "W") && $1 ~ /\.cpp\.o:/ && $NF !~ /^_Z/ &&
        $NF !~ /^(Elm_Kernel_|Eco_Kernel_|EcoSystem_|Eco_Http_|Eco_Runtime_|Eco_System_|eco_|elm_)/ &&
        $NF != "__clang_call_terminate" && $NF != "ecoSystemSignalHandler" {
            m = $1; sub(/:[0-9a-f]*$/, "", m); n = split(m, parts, ":"); print parts[n] ":" $NF }' | sort -u)
    for s in $bad; do
        echo "unmangled non-export C symbol: ${s#*:} (${s%%:*} in ${a#$root/})"
        found=1
    done
done
exit $found
