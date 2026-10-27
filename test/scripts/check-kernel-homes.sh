#!/bin/sh
# check-kernel-homes.sh — fail if a kernel home is shared where it must not be:
#   1. an eco/system kernel home collides with any other kernel home;
#   2. an eco/kernel kernel home collides with an Elm kernel home (elm/core, elm/*), other than
#      the homes listed in SHARED_ELM_ECO below.
#
# Since SD-16 the prefix is part of every kernel key: the JS backend keys and names an Eco kernel
# with it (`elm/kernel:Eco.Kernel.File.$`, `_Eco_File_size`), and KernelTypes, KernelFacts and
# KernelSetFacts key rows by (prefix, home, name) (plans/kernel-table-prefix-keys.md). So the
# eco/kernel homes File, Http and Process, which elm/file, elm/http and elm/core also have, are
# safe there. What still keys by home alone are the hard-coded elm/core dispatches
# (Generate/MLIR/Intrinsics, both KernelAbi modules, BytesFusion/Reify), which match kernels by
# (home, name) and none of which names a shared home today. A new shared home must be added to
# SHARED_ELM_ECO deliberately, after checking those dispatches for its home.
# Scans the repository only.
#
# Usage: test/scripts/check-kernel-homes.sh [REPO_ROOT]
set -eu
root=${1:-$(cd "$(dirname "$0")/../.." && pwd)}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# A: every other kernel home.
{
    # Module lists that drive the ElmKernel_* / EcoKernel_* libraries.
    awk '/^set\(ECO_(ELM_)?KERNEL_MODS/{on=1} on{print} on&&/\)/{on=0}' \
        "$root/runtime/src/codegen/CMakeLists.txt" \
        | grep -E -v 'ECO_SYSTEM_MODS|CACHE' | sed 's/set(ECO_[A-Z_]*//' | tr ' ' '\n'
    # Homes named in the compiler's fact tables: ( "Home", "name" ) keys.
    grep -h -o -E '\( *"[A-Z][A-Za-z0-9]*" *, *"[a-z]' \
        "$root/compiler/src/Compiler/GlobalOpt/KernelFacts.elm" \
        "$root/compiler/src/Compiler/MonoSolver/KernelSetFacts.elm" \
        | sed -E 's/\( *"([A-Za-z0-9]*)".*/\1/'
    # C symbol prefixes in the two existing kernel trees.
    grep -r -h -o -E '(Elm|Eco)_Kernel_[A-Z][A-Za-z0-9]*_' \
        "$root/elm-kernel-cpp/src" "$root/eco-kernel-cpp/src" \
        | sed -E 's/^(Elm|Eco)_Kernel_//; s/_$//'
    # JS kernel files of eco/kernel.
    for f in "$root"/eco-kernel-cpp/src/Eco/Kernel/*.js; do basename "$f" .js; done
} | grep -E '^[A-Z][A-Za-z0-9]*$' | sort -u > "$tmp/others"

# B: eco/system kernel homes.
for f in "$root"/system-kernel-cpp/src/Eco/Kernel/*.js; do basename "$f" .js; done | sort -u > "$tmp/system"

clash=$(comm -12 "$tmp/others" "$tmp/system")
if [ -n "$clash" ]; then
    echo "check-kernel-homes: eco/system kernel homes collide with existing kernel homes:" >&2
    echo "$clash" | sed 's/^/  /' >&2
    exit 1
fi

# C: Elm kernel homes (elm/core and the elm/* packages): the Elm module list and the C symbol
# prefixes of elm-kernel-cpp.
SHARED_ELM_ECO="File Http Process"
{
    awk '/^set\(ECO_ELM_KERNEL_MODS/{on=1} on{print} on&&/\)/{on=0}' \
        "$root/runtime/src/codegen/CMakeLists.txt" \
        | grep -E -v 'CACHE' | sed 's/set(ECO_[A-Z_]*//' | tr ' ' '\n'
    grep -r -h -o -E 'Elm_Kernel_[A-Z][A-Za-z0-9]*_' "$root/elm-kernel-cpp/src" \
        | sed -E 's/^Elm_Kernel_//; s/_$//'
} | grep -E '^[A-Z][A-Za-z0-9]*$' | sort -u > "$tmp/elm"

# D: eco/kernel kernel homes: the Eco module list, its C symbol prefixes and its JS kernel files.
{
    awk '/^set\(ECO_KERNEL_MODS/{on=1} on{print} on&&/\)/{on=0}' \
        "$root/runtime/src/codegen/CMakeLists.txt" \
        | grep -E -v 'CACHE' | sed 's/set(ECO_[A-Z_]*//' | tr ' ' '\n'
    grep -r -h -o -E 'Eco_Kernel_[A-Z][A-Za-z0-9]*_' "$root/eco-kernel-cpp/src" \
        | sed -E 's/^Eco_Kernel_//; s/_$//'
    for f in "$root"/eco-kernel-cpp/src/Eco/Kernel/*.js; do basename "$f" .js; done
} | grep -E '^[A-Z][A-Za-z0-9]*$' | sort -u > "$tmp/ecokernel"

echo "$SHARED_ELM_ECO" | tr ' ' '\n' | sort -u > "$tmp/shared"
unexpected=$(comm -12 "$tmp/elm" "$tmp/ecokernel" | comm -23 - "$tmp/shared")
if [ -n "$unexpected" ]; then
    echo "check-kernel-homes: eco/kernel kernel homes collide with Elm kernel homes (not in SHARED_ELM_ECO):" >&2
    echo "$unexpected" | sed 's/^/  /' >&2
    exit 1
fi
echo "check-kernel-homes: OK ($(wc -l < "$tmp/system") eco/system homes, $(wc -l < "$tmp/others") others;" \
    "$(wc -l < "$tmp/ecokernel") eco/kernel homes vs $(wc -l < "$tmp/elm") Elm homes, shared: $SHARED_ELM_ECO)"
