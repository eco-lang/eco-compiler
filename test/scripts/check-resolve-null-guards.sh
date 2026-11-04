#!/bin/sh
# `Allocator::resolve` never returns null (it asserts on an embedded constant, and in a build without assertions
# it dereferences the constant's made-up address), so a null test right after it is dead, and where the value can
# be a constant it hides a crash: use `alloc::resolveOrNull` (HeapHelpers.hpp) for a value that may be a constant.
# Looks for a variable assigned from `resolve(` (not `resolveOrNull(` / `resolveFast(`) whose next 4 lines test it
# for null outside an `assert`, across the kernels and the runtime. Lists every hit.
# Exit 0 = none, 1 = dead guards present.
root=${1:-.}
dirs=""
for d in elm-kernel-cpp/src eco-kernel-cpp/src system-kernel-cpp/src runtime/src; do
    [ -d "$root/$d" ] && dirs="$dirs $root/$d"
done
[ -n "$dirs" ] || { echo "no source dirs under $root"; exit 2; }
hits=$(find $dirs -type f \( -name '*.cpp' -o -name '*.hpp' -o -name '*.h' \) | sort |
    xargs awk '
    FNR == 1 { var = ""; left = 0 }
    {
        line = $0
        if (left > 0 && var != "" && line !~ /assert *\(/) {
            left--
            v = var
            if (line ~ ("if *\\( *! *" v "[^A-Za-z0-9_]") ||
                line ~ ("if *\\( *" v " *(\\)|&&)") ||
                line ~ ("[(=,!] *" v " *\\?") ||
                line ~ ("(==|!=) *nullptr") && line ~ ("[^A-Za-z0-9_]" v "[^A-Za-z0-9_]")) {
                printf "%s:%d: %s (null test of %s from resolve at line %d)\n", FILENAME, FNR, line, v, at
                var = ""; left = 0
            }
        }
        if (match(line, /[A-Za-z_][A-Za-z0-9_]* *= *[^;=]*[^A-Za-z0-9_]resolve\(/) &&
            line !~ /resolveOrNull|resolveFast/) {
            s = substr(line, RSTART, RLENGTH)
            sub(/ *=.*/, "", s)
            var = s; left = 4; at = FNR
        }
    }')
if [ -n "$hits" ]; then
    printf '%s\n' "$hits" | sed "s|$root/||"
    echo "$(printf '%s\n' "$hits" | wc -l) dead null guard(s) after Allocator::resolve"
    exit 1
fi
exit 0
