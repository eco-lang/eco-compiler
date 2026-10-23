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
# Note: the `// RUN: %ecoc ... | %FileCheck %s` headers in the .mlir
# fixtures are not executed by lit (there is no lit config). The C++
# driver only scans the RUN line for the `-emit=` mode, a leading
# `not %ecoc` (expected non-zero exit) and a small whitelist of
# pass-through ecoc flags (`--exe-reachability`); the rest of the
# `%ecoc ... | %FileCheck %s` pipeline is decorative. CHECK lines are
# matched by test/CheckPatterns.hpp, not by FileCheck.
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
