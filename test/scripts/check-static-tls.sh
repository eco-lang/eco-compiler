#!/bin/sh
# A program loaded as a shared library (a Node addon, an aot-port-host .so) holds its thread_locals in
# static TLS, and glibc gives a dlopened library only its small surplus: here 2.36 loads 1,664 B and refuses
# 2,048 B, less what the host process has already used. A larger segment fails with "cannot allocate memory
# in static TLS block" (the PR #17 literal table, 8.3 KB; the WebSocket mask pool, 4 KB).
#
# Sums the defined TLS symbols (readelf -s type TLS) of the archives a program links: the runtime's
# EcoRuntimeStatic, EcoEntryStatic, EcoEmbedStatic and EcoNodeGlue, and every kernel archive (elm-kernel-cpp
# ElmKernel_*, eco-kernel-cpp EcoKernel_*, system-kernel-cpp EcoSystem_*). The sum over all of them bounds any
# one program. Fails if it exceeds 1,024 B or if one symbol exceeds 512 B (as LiteralTable's static_assert);
# keep a large per-thread buffer on the heap behind a thread_local pointer instead.
#
# Build directory: $ECO_BUILD_DIR, else <repo-root>/build, so run it after the build.
# Exit 0 = within budget, 1 = over, 2 = no archives (build first).
root=${1:-.}
build=${ECO_BUILD_DIR:-$root/build}
total_max=1024
symbol_max=512
archives=$(ls "$build"/runtime/src/codegen/libEcoRuntimeStatic.a "$build"/runtime/src/codegen/libEcoEntryStatic.a \
               "$build"/runtime/src/codegen/libEcoEmbedStatic.a "$build"/runtime/src/codegen/libEcoNodeGlue.a \
               "$build"/elm-kernel-cpp/libElmKernel_*.a "$build"/eco-kernel-cpp/libEcoKernel_*.a \
               "$build"/system-kernel-cpp/libEcoSystem_*.a 2>/dev/null)
[ -n "$archives" ] || { echo "no runtime or kernel archives under $build (build first)"; exit 2; }
for a in $archives; do
    readelf -sW "$a" 2>/dev/null | awk -v a="${a#$root/}" '
        /^File: / { m = $2; sub(/.*\(/, "", m); sub(/\)$/, "", m) }
        $4 == "TLS" && $7 != "UND" && $3 > 0 { print $3, a "(" m ")", $8 }'
done | awk -v total_max=$total_max -v symbol_max=$symbol_max '
    { total += $1
      if ($1 + 0 > symbol_max + 0) { printf "thread_local over %d B: %s, %d B, in %s\n", symbol_max, $3, $1, $2; bad = 1 } }
    END {
      if (total > total_max + 0) { printf "static TLS over budget: %d B > %d B across the program archives\n", total, total_max; bad = 1 }
      else printf "check-static-tls: ok (%d B of %d B)\n", total, total_max
      exit bad }'
