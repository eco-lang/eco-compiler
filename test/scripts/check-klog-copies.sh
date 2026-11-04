#!/bin/sh
# The debug-log macro ECO_KLOG is defined in elm-kernel-cpp/src/KernelDebug.hpp,
# eco-kernel-cpp/src/eco-kernel/KernelDebug.hpp and runtime/src/platform/HttpService.cpp (the layers cannot share
# a header). This extracts each file's `#define ECO_KLOG` lines (with their continuation lines,
# whitespace-normalised) and fails when the copies differ. A file that includes a shared header instead defines
# nothing and is skipped; at least one definition must remain.
# Exit 0 = the copies agree (or there is one), 1 = they differ.
root=${1:-.}
files="elm-kernel-cpp/src/KernelDebug.hpp eco-kernel-cpp/src/eco-kernel/KernelDebug.hpp runtime/src/platform/HttpService.cpp"
tmp=$(mktemp -d /tmp/check-klog-copies.XXXXXX)
trap 'rm -rf "$tmp"' EXIT
ref=""
n=0
status=0
for f in $files; do
    p="$root/$f"
    [ -f "$p" ] || { echo "no $p"; exit 2; }
    out="$tmp/$n.txt"
    # Every #define ECO_KLOG line, joined with its backslash continuations.
    awk '
        function strip(s) { sub(/\\[ \t]*$/, "", s); return s }
        cont { line = line " " strip($0); if ($0 !~ /\\[ \t]*$/) { print line; cont = 0 }; next }
        /^[ \t]*#[ \t]*define[ \t]+ECO_KLOG[ \t(]/ {
            line = strip($0); if ($0 ~ /\\[ \t]*$/) { cont = 1 } else { print line }
        }
    ' "$p" | sed -e 's/[ \t][ \t]*/ /g' -e 's/^ //' -e 's/ $//' >"$out"
    if [ ! -s "$out" ]; then
        echo "$f: no ECO_KLOG definition (uses a shared header?)"
        n=$((n + 1)); continue
    fi
    echo "$f: $(wc -l <"$out") definition(s)"
    if [ -z "$ref" ]; then
        ref="$out"; reff="$f"
    elif ! cmp -s "$ref" "$out"; then
        echo "ECO_KLOG in $f differs from $reff:"
        diff "$ref" "$out"
        status=1
    fi
    n=$((n + 1))
done
[ -n "$ref" ] || { echo "no ECO_KLOG definition found at all"; exit 2; }
exit $status
