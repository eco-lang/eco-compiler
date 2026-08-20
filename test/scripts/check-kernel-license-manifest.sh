#!/bin/sh
# check-kernel-license-manifest.sh — LSS_022 license-rot guard.
#
#   usage: check-kernel-license-manifest.sh <repo-root> [--update]
#
# A KernelSetFacts `TypeFaithful` row is a CONTRACT ON C++ THAT ELM CANNOT
# SEE. The row says "this kernel's set flow is exactly its Elm type's
# variable-sharing graph", and the compiler then skips the LSS_004 poison at
# every call to it. A later edit to the audited C++ body can invalidate that
# silently — and the failure mode is a wrong direct-call stamp, i.e. a
# miscompile, not a test failure. Elm tests cannot read files, so the guard
# lives here, in the build tree.
#
# Two directions are checked, and BOTH matter:
#
#   1. HASH: every C++ file a licensed row depends on still has the sha256 it
#      had when the audit was performed.
#   2. COVERAGE: the (kernel, file) pairs pinned by the manifest are exactly
#      the pairs the `TypeFaithful` rows declare. This catches the other
#      failure — a new licensed row landing with no manifest entry, which
#      would otherwise be unguarded forever.
#
# `--update` regenerates the manifest from the current rows and file
# contents. Running it is the LAST step of a re-audit, never a way to make a
# red build green: bumping a hash without advancing the row's `audited:` date
# in its evidence string is precisely the review violation this guard exists
# to surface.
#
# Scope note (deliberate): the manifest pins the kernel's OWN C++ — the entry
# point's file and the helper files the audit had to read. It does NOT pin
# globally-sanctioned runtime machinery (the four `eco_apply_closure*`
# application entries, allocator/list-builder headers). Those are shared by
# every kernel and are not a per-license risk; pinning them would rot every
# row on unrelated allocator churn while adding no per-kernel signal.

set -e

ROOT="$1"
MODE="$2"

if [ -z "$ROOT" ] || [ ! -d "$ROOT" ]; then
    echo "check-kernel-license-manifest: usage: $0 <repo-root> [--update]" >&2
    exit 2
fi

FACTS="$ROOT/compiler/src/Compiler/MonoSolver/KernelSetFacts.elm"
INTRINSICS="$ROOT/compiler/src/Compiler/Type/KernelIntrinsics.elm"
MANIFEST="$ROOT/compiler/src/Compiler/MonoSolver/kernel-license-manifest.txt"

if [ ! -f "$FACTS" ]; then
    echo "check-kernel-license-manifest: cannot read $FACTS" >&2
    exit 2
fi

if [ ! -f "$INTRINSICS" ]; then
    echo "check-kernel-license-manifest: cannot read $INTRINSICS" >&2
    exit 2
fi

# --- sha256 front-end (Linux coreutils / BSD / macOS) ------------------------
sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | cut -d' ' -f1
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | cut -d' ' -f1
    else
        echo "check-kernel-license-manifest: no sha256sum or shasum on PATH" >&2
        exit 2
    fi
}

TMP="${TMPDIR:-/tmp}/kernel-license-$$"
mkdir -p "$TMP"
trap 'rm -rf "$TMP"' EXIT

# --- extract (kernel, file) pairs from the TypeFaithful rows -----------------
#
# The table's shape is fixed by elm-format, so a small state machine is
# enough and avoids a Python dependency in the build graph:
#
#     , ( ( "JsArray", "map" )
#       , TypeFaithful
#             { files = [ "elm-kernel-cpp/src/core/JsArrayExports.cpp" ]
#             , evidence = "..."
#             }
#       )
#
# A `( ( "Home", "name" )` line opens a row (resetting the licensed flag, so
# a `Positional` row contributes nothing); `files = [ ... ]` is collected
# across lines until its closing bracket.
awk '
    {
        if ($0 ~ /\( \( "[^"]+", "[^"]+" \)/) {
            s = $0
            sub(/^[^(]*\( \( "/, "", s)
            h = s
            sub(/".*/, "", h)
            t = s
            sub(/^[^"]*", "/, "", t)
            sub(/".*/, "", t)
            kernel = h "." t
            licensed = 0
            collecting = 0
        }
        if ($0 ~ /TypeFaithful/) { licensed = 1 }
        if (licensed && $0 ~ /files[ ]*=/) { collecting = 1 }
        if (collecting) {
            rest = $0
            while (match(rest, /"[^"]*"/)) {
                v = substr(rest, RSTART + 1, RLENGTH - 2)
                print kernel "\t" v
                rest = substr(rest, RSTART + RLENGTH)
            }
            if ($0 ~ /\]/) { collecting = 0 }
        }
    }
' "$FACTS" > "$TMP/declared.raw"

# --- the same, for the INTRINSIC ANNOTATION table ----------------------------
#
# An intrinsic annotation is the same species of claim as a license — a
# statement about a C++ body that Elm cannot see — so it is pinned the same way.
# Its rows are keyed by a THREE-tuple (prefix, home, name) and every row has
# `files`, so the state machine is the license one minus the TypeFaithful flag:
#
#     , ( ( "Elm", "List", "fromArray" )
#       , { annotation = ...
#         , files = [ "elm-kernel-cpp/src/core/ListExports.cpp" ]
#         }
#       )
#
# Labelled `<Prefix>.Kernel.<Home>.<name>` so an intrinsic pin is never confused
# with a license pin on the same file.
awk '
    {
        if ($0 ~ /\( \( "[^"]+", "[^"]+", "[^"]+" \)/) {
            s = $0
            sub(/^[^(]*\( \( "/, "", s)
            p = s
            sub(/".*/, "", p)
            t = s
            sub(/^[^"]*", "/, "", t)
            h = t
            sub(/".*/, "", h)
            n = t
            sub(/^[^"]*", "/, "", n)
            sub(/".*/, "", n)
            kernel = p ".Kernel." h "." n
            collecting = 0
        }
        if (kernel != "" && $0 ~ /files[ ]*=/) { collecting = 1 }
        if (collecting) {
            rest = $0
            while (match(rest, /"[^"]*"/)) {
                v = substr(rest, RSTART + 1, RLENGTH - 2)
                print kernel "\t" v
                rest = substr(rest, RSTART + RLENGTH)
            }
            if ($0 ~ /\]/) { collecting = 0 }
        }
    }
' "$INTRINSICS" >> "$TMP/declared.raw"

sort -u "$TMP/declared.raw" > "$TMP/declared"

# --- --update: regenerate the manifest ---------------------------------------
if [ "$MODE" = "--update" ]; then
    # ASCII ONLY in this header, deliberately. test/CMakeLists.txt reads the
    # manifest with file(STRINGS), which splits lines at non-ASCII bytes; a
    # header containing a section sign or an em dash gets torn into fragments,
    # and a fragment like "2 checklist - see" happily matches a
    # "<hex> <path> <rest>" pattern. That produced a phantom dependency on a
    # file named "checklist" and broke the build graph once already.
    {
        echo "# LSS_022 kernel parametricity license - rot manifest."
        echo "# GENERATED by test/scripts/check-kernel-license-manifest.sh --update."
        echo "#"
        echo "# One line per (licensed kernel x audited C++ file):"
        echo "#     <sha256>  <repo-relative path>  <Home.name>"
        echo "#"
        echo "# A hash mismatch means the audited body changed and the license"
        echo "# must be re-established by re-running the checklist in"
        echo "# plans/kernel-parametricity-license.md section 2. Regenerating a"
        echo "# hash without advancing the row's 'audited:' date is the"
        echo "# violation, not the fix."
    } > "$MANIFEST.new"

    while IFS="$(printf '\t')" read -r kernel file; do
        [ -n "$kernel" ] || continue
        if [ ! -f "$ROOT/$file" ]; then
            echo "check-kernel-license-manifest: $kernel lists a file that does not exist: $file" >&2
            exit 1
        fi
        echo "$(sha256_of "$ROOT/$file")  $file  $kernel"
    done < "$TMP/declared" | sort -k3,3 -k2,2 >> "$MANIFEST.new"

    mv "$MANIFEST.new" "$MANIFEST"
    echo "check-kernel-license-manifest: wrote $(grep -c '^[0-9a-f]' "$MANIFEST") pins to $MANIFEST"
    exit 0
fi

# --- check mode --------------------------------------------------------------
if [ ! -f "$MANIFEST" ]; then
    if [ ! -s "$TMP/declared" ]; then
        # No licensed rows and no manifest: consistent (the Wave-0 state).
        exit 0
    fi
    echo "check-kernel-license-manifest: $MANIFEST is missing, but KernelSetFacts.elm" >&2
    echo "  declares licensed kernels. Run: $0 $ROOT --update" >&2
    exit 1
fi

grep '^[0-9a-f]' "$MANIFEST" | awk '{ print $3 "\t" $2 }' | sort -u > "$TMP/pinned"

STATUS=0

if ! diff -u "$TMP/pinned" "$TMP/declared" > "$TMP/coverage.diff" 2>&1; then
    echo "check-kernel-license-manifest: MANIFEST COVERAGE MISMATCH" >&2
    echo "  The (kernel, file) pairs pinned by the manifest differ from the ones" >&2
    echo "  the TypeFaithful rows in KernelSetFacts.elm declare." >&2
    echo "  '-' lines are pinned but no longer declared; '+' lines are declared" >&2
    echo "  but unpinned — an UNGUARDED license." >&2
    echo "" >&2
    sed 's/^/  /' "$TMP/coverage.diff" >&2
    echo "" >&2
    echo "  Fix: re-audit per plans/kernel-parametricity-license.md §2, then run" >&2
    echo "       $0 $ROOT --update" >&2
    STATUS=1
fi

grep '^[0-9a-f]' "$MANIFEST" | while read -r want file kernel; do
    if [ ! -f "$ROOT/$file" ]; then
        echo "check-kernel-license-manifest: kernel $kernel is licensed against" >&2
        echo "  $file, which no longer exists." >&2
        echo "  Re-audit per plans/kernel-parametricity-license.md §2 and update" >&2
        echo "  the manifest." >&2
        echo "FAIL" >> "$TMP/hashfail"
        continue
    fi
    got=$(sha256_of "$ROOT/$file")
    if [ "$got" != "$want" ]; then
        echo "check-kernel-license-manifest: kernel $kernel is licensed against a C++" >&2
        echo "  body that has changed — $file" >&2
        echo "    pinned:  $want" >&2
        echo "    current: $got" >&2
        echo "  Re-audit per plans/kernel-parametricity-license.md §2 (application-only" >&2
        echo "  through the sanctioned entry points, no retention, no fabrication or" >&2
        echo "  laundering, honest type), then update the manifest hash AND advance the" >&2
        echo "  row's 'audited:' date in its evidence string. Updating the hash without" >&2
        echo "  a re-audit note is the violation this check exists to catch." >&2
        echo "  If the kernel can no longer be licensed, demote the row to Positional" >&2
        echo "  or delete it — a wrong license is a miscompile, a missing one costs" >&2
        echo "  only precision." >&2
        echo "FAIL" >> "$TMP/hashfail"
    fi
done

if [ -f "$TMP/hashfail" ]; then
    STATUS=1
fi

exit $STATUS
