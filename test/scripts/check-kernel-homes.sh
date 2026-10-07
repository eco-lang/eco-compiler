#!/bin/sh
# check-kernel-homes.sh — fail if an eco/system kernel home collides with any other kernel home.
#
# Kernel homes are keyed WITHOUT their Elm/Eco prefix in kernel typing, KernelFacts,
# KernelSetFacts, the JS globals (_Home_name) and the JS graph key, so a home reused by two
# packages silently shares facts or drops a node (plans/eco-system-library.md F8, Phase 1 step 1).
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
echo "check-kernel-homes: OK ($(wc -l < "$tmp/system") eco/system homes, $(wc -l < "$tmp/others") others)"
