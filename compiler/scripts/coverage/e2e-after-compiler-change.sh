#!/bin/sh
# Runs the whole JIT E2E suite after a change to compiler/src, the way the coverage loop's bug
# fixes are checked (plans/coverage-driven-test-generation.md, "Bugs found by the loop").
#
# The E2E harness reuses a test's .mlir while it is newer than the .elm, and package artifacts in
# ~/.eco while they exist, so neither notices a compiler change. This script rebuilds guida.js,
# moves both caches aside under /tmp, and runs build/test/test once, holding the lock that keeps
# test binaries of this tree from running at the same time. Output: /tmp/test_output.txt.
set -eu
# The codegen fixtures look up build/runtime/... relative to the current directory.
cd /work
BUILD=/work/build
LOCK=/tmp/eco-cov-e2e.lock
ASIDE=/tmp/eco-cov-e2e-aside.$$

exec 9>"$LOCK"
flock 9

# Inside the lock: two fixers may edit compiler/src at once, and each run must build and test
# one snapshot of it.
cmake --build "$BUILD" --target guida

mkdir -p "$ASIDE/eco-stuff" "$ASIDE/eco-home"
for d in "$BUILD"/test/*/eco-stuff; do
    [ -d "$d" ] && mv "$d" "$ASIDE/eco-stuff/$(basename "$(dirname "$d")")"
done
for v in "$HOME"/.eco/*/packages; do
    [ -d "$v" ] || continue
    find "$v" -name '*artifacts.dat' | while read -r f; do
        rel=${f#"$HOME"/.eco/}
        mkdir -p "$ASIDE/eco-home/$(dirname "$rel")"
        mv "$f" "$ASIDE/eco-home/$rel"
    done
done

ulimit -c 0
"$BUILD"/test/test 2>&1 | tee /tmp/test_output.txt | grep -E '^(Tests run|Tests passed|Tests failed|Result):'
echo "old caches moved to $ASIDE (delete when done)"
