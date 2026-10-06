#!/usr/bin/env bash
# Generic-call census over the E2E corpus
# (plans/staging-honesty-and-production-test-pipeline.md P0.3). The staging
# class/wrapper census of P0.2 (`lss staging:`) was removed with the staging
# solver in P3; this now sums the `lss gencall:` line.
#
# Usage: test/scripts/staging-census.sh <native-eco-compiler> [out-dir]
#
# Compiles every test/<pkg>/src/*Test.elm that defines `main` with the given
# native compiler under ECO_STAGING_REPORT=1, keeps each test's
# `lss gencall:` line, and prints the per-counter sums. Compiles happen in a scratch copy of each package (so no eco-stuff is
# written into the source tree); a test that fails to compile is counted and
# listed, not fatal.
set -u

COMPILER="${1:?usage: $0 <native-eco-compiler> [out-dir]}"
OUT="${2:-$(mktemp -d /tmp/staging-census.XXXXXX)}"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
mkdir -p "$OUT"
: > "$OUT/lines.txt"
: > "$OUT/failed.txt"

for pkgdir in "$REPO"/test/*/; do
    pkg="$(basename "$pkgdir")"
    [ -f "$pkgdir/elm.json" ] && [ -d "$pkgdir/src" ] || continue
    shadow="$OUT/shadow/$pkg"
    mkdir -p "$shadow"
    cp "$pkgdir/elm.json" "$shadow/"
    rm -rf "$shadow/src"
    ln -s "$pkgdir/src" "$shadow/src"
    for f in "$pkgdir"/src/*Test.elm; do
        [ -f "$f" ] || continue
        grep -qE '^main( |:|=)' "$f" || continue
        stem="$(basename "$f" .elm)"
        log="$OUT/logs/$pkg-$stem.log"
        mkdir -p "$OUT/logs"
        ( cd "$shadow" && ECO_STAGING_REPORT=1 "$COMPILER" make \
              --builddir=staging-census --kernel-package eco/compiler \
              --local-package "eco/kernel=$REPO/eco-kernel-cpp" \
              --output="$OUT/out.mlir" "src/$stem.elm" ) > "$log" 2>&1
        if grep -aq '^lss gencall:' "$log"; then
            grep -a -E '^lss gencall:' "$log" | sed "s|^|$pkg/$stem |" >> "$OUT/lines.txt"
        else
            echo "$pkg/$stem" >> "$OUT/failed.txt"
        fi
    done
done

echo "tests censused: $(grep -c 'lss gencall:' "$OUT/lines.txt")  failed: $(wc -l < "$OUT/failed.txt")"
# Sum every key=value pair.
grep -a -o -E '[A-Za-z]+(:[A-Za-z]+)?(\+[A-Za-z]+)*=[0-9]+' "$OUT/lines.txt" \
    | awk -F= '{ s[$1] += $2 } END { for (k in s) printf "%s=%d\n", k, s[k] }' | sort
echo "details: $OUT"
