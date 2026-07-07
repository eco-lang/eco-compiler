#!/bin/bash
#
# DEPRECATED — this grep-based runner has been retired.
#
# The codegen .mlir suite is now driven by the C++ test driver
# CodegenIsolatedTest.hpp, wired into the main `test/test` binary
# (test/main.cpp). That driver supersedes this script because it:
#
#   * runs JIT tests IN-PROCESS via EcoRunner, so runtime accessor
#     symbols (eco_tuple2_get*, eco_record_get*, ...) resolve — the
#     standalone-`ecoc` JIT here could not register them;
#   * honors `XFAIL:` markers and negative (`RUN: not`) tests instead
#     of mis-scoring them; and
#   * needs no external FileCheck or separately-built `ecoc`.
#
# See jit-test-tidy.md for the full write-up.
#
# This stub forwards to the C++ driver so existing muscle memory /
# scripts keep working.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEST_BIN="${SCRIPT_DIR}/../../build/test/test"

if [ ! -x "$TEST_BIN" ]; then
    echo "Error: test binary not found at $TEST_BIN"
    echo "Build with: cmake --build build --target test"
    exit 1
fi

# Forward an optional name filter; default to the whole codegen suite.
# (The C++ driver filters by test-name substring, e.g. "codegen/float".)
FILTER="${1:-codegen}"

echo ">>> run_tests.sh is deprecated; forwarding to the C++ codegen driver:"
echo ">>>   $TEST_BIN --filter $FILTER"
echo ""
exec "$TEST_BIN" --filter "$FILTER"
