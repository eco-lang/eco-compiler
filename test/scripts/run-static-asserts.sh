#!/bin/sh
# Compiles each static_assert translation unit under test/static-asserts/*.cpp with -fsyntax-only and the
# project's flags, and prints one row per file: compile-ok (every asserted property holds) or compile-fail.
# Exits 0 when every file compiles, 1 otherwise. `check` and `full` run it after the build.
#
# Flags: the compile command of a reference source in the build tree (`ninja -t compdb`), default
# system-kernel-cpp/src/eco-system/Core/Core.cpp; a file overrides it with a line
#   // STATIC-ASSERT-REF: <repo-relative source, e.g. elm-kernel-cpp/src/time/Time.cpp>
# Every kernel and runtime source directory is added to the include path as well.
#
# Usage: sh test/scripts/run-static-asserts.sh [<build-dir>] [<name-substring>]
#   (build dir default: <repo>/build; diagnostics shown for compile-fail, or always with
#   STATIC_ASSERTS_VERBOSE=1)

set -u
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
build=${1:-$root/build}
filter=${2:-}
dir="$root/test/static-asserts"

tmp=$(mktemp -d /tmp/static-asserts.XXXXXX)
trap 'rm -rf "$tmp"' EXIT
cdb="$tmp/compdb.json"
if [ -f "$build/build.ninja" ]; then
    ninja -C "$build" -t compdb >"$cdb" 2>/dev/null || echo "[]" >"$cdb"
else
    echo "[]" >"$cdb"
fi

# Prints the flags (no -o/-c/-M*, no source) of reference source $1, one per line.
ref_flags() {
    python3 - "$cdb" "$root/$1" <<'PY'
import json, shlex, sys
db, ref = sys.argv[1], sys.argv[2]
for e in json.load(open(db)):
    if e.get("file") == ref:
        args = e.get("arguments") or shlex.split(e["command"])
        out, skip = [], False
        for a in args[1:]:
            if skip:
                skip = False
                continue
            if a in ("-o", "-MT", "-MF", "-c"):
                skip = a != "-c"
                continue
            if a in ("-MD", "-MMD") or a == e["file"]:
                continue
            out.append(a)
        print("\n".join(out))
        break
PY
}

compiler=${CXX:-}
if [ -z "$compiler" ]; then
    compiler=$(python3 -c "
import json,shlex,sys
d=json.load(open('$cdb'))
print(shlex.split(d[0]['command'])[0] if d else 'clang++')" 2>/dev/null || echo clang++)
fi

extra="-std=gnu++20 -I$root/runtime/src -I$root/runtime/src/allocator -I$root/runtime/src/platform
-I$root/runtime/src/codegen -I$build/runtime/src/codegen/include -I$root/elm-kernel-cpp/src
-I$root/eco-kernel-cpp/src -I$root/system-kernel-cpp/src -I$root/test"

ok=0
bad=0
rows=""
for f in "$dir"/*.cpp; do
    [ -e "$f" ] || continue
    name=$(basename "$f")
    case "$name" in *"$filter"*) ;; *) continue ;; esac
    ref=$(sed -n 's|^// STATIC-ASSERT-REF: *||p' "$f" | head -n 1)
    ref=${ref:-system-kernel-cpp/src/eco-system/Core/Core.cpp}
    flags=$(ref_flags "$ref")
    if [ -z "$flags" ]; then
        echo "note: $name: no compile command for $ref in $build; using default flags"
    fi
    # shellcheck disable=SC2086
    (cd "$build" 2>/dev/null || cd "$root"; $compiler $(echo "$flags" | tr '\n' ' ') $extra -fsyntax-only "$f") \
        >"$tmp/out" 2>&1
    if [ $? -eq 0 ]; then
        status=compile-ok
        ok=$((ok + 1))
    else
        status="compile-fail"
        bad=$((bad + 1))
    fi
    if [ "$status" != compile-ok ] || [ "${STATIC_ASSERTS_VERBOSE:-0}" = 1 ]; then
        echo "--- $name: $status"
        grep -E "error|static assertion|note: expression" "$tmp/out" | head -n 20 | sed 's/^/    /'
    fi
    rows="$rows$(printf '%-40s | %s' "$name" "$status")
"
done

echo
printf '%-40s | %s\n' "file" "result"
printf '%-40s-+-%s\n' "----------------------------------------" "------"
printf '%s' "$rows"
echo
echo "$ok compile-ok, $bad compile-fail"
[ "$bad" -eq 0 ]
