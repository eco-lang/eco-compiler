#!/bin/sh
# Command-line checks of the eco-boot-native driver that need no Elm program.
#
#   usage: check-driver-cli.sh <repo-root> <build-dir>
#
# Each check asserts the correct behaviour. A check marked XFAIL reproduces an open defect from
# cpp-review-bugs.md, with the convention of test/XfailGuard.hpp: it passes while the defect
# reproduces and fails as XPASS once it does not (the defect looks fixed: drop the mark);
# ECO_TEST_XFAIL=strict makes it fail on today's code.
set -eu

ROOT=${1:?usage: check-driver-cli.sh <repo-root> <build-dir>}
BUILD=${2:?usage: check-driver-cli.sh <repo-root> <build-dir>}
DRIVER="$BUILD/runtime/src/codegen/eco-boot-native"
WORK="$BUILD/test/driver-cli"
rm -rf "$WORK"
mkdir -p "$WORK"
ulimit -c 0

failed=0
# result <name> <xfail: 0|1> <ok: 0|1> <what was seen>
result() {
    name=$1; xfail=$2; ok=$3; seen=$4
    if [ "$xfail" = 1 ] && [ "${ECO_TEST_XFAIL:-}" != strict ]; then
        if [ "$ok" = 1 ]; then
            echo "FAIL driver-cli/$name: XPASS ($seen) -- the defect looks fixed; drop its XFAIL mark"
            failed=$((failed + 1))
        else
            echo "XFAIL driver-cli/$name: $seen"
        fi
    elif [ "$ok" = 1 ]; then
        echo "PASS driver-cli/$name"
    else
        echo "FAIL driver-cli/$name: $seen"
        failed=$((failed + 1))
    fi
}

# RB-780 (cpp-review-bugs.md "eco-boot CLI edge cases"): --emit=mlir on a .mlir input must print
# MLIR on stdout (or refuse with an error). getOutputPath returns "-" for EmitMLIR, and for a .mlir
# input main skips the Elm-only EmitMLIR return and falls into the executable path, so today it
# links an executable into a file named "-" and exits 0.
d="$WORK/emit-mlir"
mkdir -p "$d"
rc=0
( cd "$d" && "$DRIVER" --emit=mlir "$ROOT/test/codegen/arithmetic_bitwise.mlir" > out 2> err ) || rc=$?
if [ -e "$d/-" ]; then
    result emit-mlir-on-mlir-input 1 0 "exit $rc; linked an executable into a file named '-'"
elif [ "$rc" -eq 0 ] && grep -q 'module' "$d/out"; then
    result emit-mlir-on-mlir-input 1 1 "printed MLIR"
elif [ "$rc" -ne 0 ] && [ -s "$d/err" ]; then
    result emit-mlir-on-mlir-input 1 1 "refused with an error"
else
    result emit-mlir-on-mlir-input 1 0 "exit $rc; no MLIR on stdout and no error"
fi
rm -f "$d/-"

if [ "$failed" -ne 0 ]; then
    echo "driver-cli: $failed FAILED"
    exit 1
fi
echo "driver-cli: all passed"
