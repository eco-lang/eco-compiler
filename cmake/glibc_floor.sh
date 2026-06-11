#!/usr/bin/env bash
# glibc_floor.sh — part 2 of the Stage D glibc-runtime audit (invoked by
# cmake/GlibcRuntimeAudit.cmake; see plans/stage-d-hybrid-link-profiles.md
# step 2).
#
# The Stage D link binds no libc, so produced .so/.node carry unversioned
# UND refs and NO DT_VERNEED — nothing enforces a glibc version at load
# time. Compute the honest floor here instead: collect the undefined
# symbols of all staged archives (minus those defined elsewhere in the
# tree), look each up in the BUILD host's libc/libm dynamic export tables
# (default versions are what unversioned references bind to), and record
# the maximum.
#
# Usage: glibc_floor.sh <tree-dir> <nm> <objdump>
# Outputs: <tree>/UND_SYMBOLS.txt, <tree>/GLIBC_FLOOR (e.g. "2.34").
set -euo pipefail
# C collation throughout — join(1) requires its inputs sorted under the
# same collation it compares with, and locale sorts order '_'/tabs
# differently than byte order.
export LC_ALL=C

tree=$1; nm=$2; objdump=$3

und=$(mktemp); def=$(mktemp); exports=$(mktemp)
trap 'rm -f "$und" "$def" "$exports"' EXIT

archives=$(find "$tree" -name '*.a' | sort)

# Undefined minus tree-defined = truly external references. NF>=2 drops
# blank lines and "member.o:" archive headers from nm output.
for a in $archives; do "$nm" -u "$a" 2>/dev/null | awk 'NF>=2{print $NF}'; done | sort -u > "$und"
for a in $archives; do "$nm" --defined-only "$a" 2>/dev/null | awk 'NF>=3{print $3}'; done | sort -u > "$def"
comm -23 "$und" "$def" > "$tree/UND_SYMBOLS.txt"

libs=""
for cand in /lib/x86_64-linux-gnu/libc.so.6 /lib64/libc.so.6 /usr/lib/x86_64-linux-gnu/libc.so.6; do
    if [ -e "$cand" ]; then libs="$libs $cand"; break; fi
done
for cand in /lib/x86_64-linux-gnu/libm.so.6 /lib64/libm.so.6 /usr/lib/x86_64-linux-gnu/libm.so.6; do
    if [ -e "$cand" ]; then libs="$libs $cand"; break; fi
done
if [ -z "$libs" ]; then
    echo "glibc_floor: no host libc.so.6 found" >&2
    exit 1
fi

# objdump -T defined-export lines end "... <VERSION> <name>"; default
# versions print bare (GLIBC_2.34), non-default in parens ((GLIBC_2.2.5))
# — only bare ones matter, they're what unversioned refs bind to.
for lib in $libs; do "$objdump" -T "$lib"; done 2>/dev/null \
    | awk 'NF>=6 && $4 != "*UND*" && $(NF-1) ~ /^GLIBC_[0-9.]+$/ { print $NF "\t" $(NF-1) }' \
    | sort -u > "$exports"

floor=$(join -t "$(printf '\t')" "$tree/UND_SYMBOLS.txt" "$exports" \
    | cut -f2 | sed 's/^GLIBC_//' | sort -uV | tail -1)

if [ -z "$floor" ]; then
    echo "glibc_floor: floor computation matched no symbols" >&2
    exit 1
fi

echo "$floor" > "$tree/GLIBC_FLOOR"
echo "glibc_floor: glibc floor = $floor ($(wc -l < "$tree/UND_SYMBOLS.txt") external UND symbols)"
