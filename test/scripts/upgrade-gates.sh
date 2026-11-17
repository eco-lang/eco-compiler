#!/usr/bin/env bash
# The Linux acceptance gates for moving a pin in deps/versions.env (LLVM or MAX), run once, in
# order, stopping at the first failure (plans/llvm-24-upgrade.md §7):
#
#   1. scripts/deps.sh check     the pins are consistent (and LLVM is MAX's own pin)
#   2. fresh configure           cmake --fresh (a new cache), MAX required (ECO_MAX=ON)
#   3. full                      clean rebuild, JIT E2E, JS E2E, Node addon, driver CLI and the
#                                MAX smoke test (load, compile and run a graph, the module guard)
#   4. elm-tests                 the compiler's Elm suite
#   5. bootstrap                 the 9-stage self-host chain and its fixed points
#   6. run-aot-e2e               Gate B (FlagsRecordTest and PortEchoTest are tolerated, as in CI)
#
# Run it inside the dev container, on the LLVM the pin names (dev.sh checks that). Output goes to
# the terminal and to $ECO_GATES_LOG (default /tmp/upgrade-gates.txt): read that file for details
# rather than running the gates again. The macOS and Windows equivalents are the mac-aot and
# win-aot workflows.
#
#   test/scripts/upgrade-gates.sh [BUILD_DIR]      (default build; `full` cleans it)
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$root"
build="${1:-build}"
log="${ECO_GATES_LOG:-/tmp/upgrade-gates.txt}"
export NODE_OPTIONS="${NODE_OPTIONS:---max-old-space-size=12000}"

case "$build" in
  /*|*..*) echo "upgrade-gates: give a build directory inside the repository, not $build" >&2; exit 2 ;;
esac

exec > >(tee "$log") 2>&1
step() { echo; echo "=== upgrade-gates: $* ($(date '+%H:%M:%S')) ==="; }

step "1. pins"
scripts/deps.sh check

step "2. fresh configure of $build (MAX required)"
cmake --preset build -B "$build" --fresh -DECO_MAX=ON

step "3. full"
cmake --build "$build" --target full

step "4. elm-tests"
set +e
cmake --build "$build" --target elm-tests > "$log.elm-tests" 2>&1
rc=$?
set -e
tail -5 "$log.elm-tests"
if [ "$rc" -ne 0 ]; then
  # elm-test-rs reports a Test.skip as an incomplete run; that is not a failure.
  if { [ "$rc" -eq 1 ] || [ "$rc" -eq 2 ]; } && grep -qE 'Failed: +0' "$log.elm-tests"; then
    echo "OK: elm-tests passed (Test.skip incomplete, no failures)"
  else
    echo "upgrade-gates: elm-tests failed (rc=$rc); see $log.elm-tests"; exit "$rc"
  fi
fi

step "5. bootstrap"
cmake --build "$build" --target bootstrap

step "6. Gate B (AOT E2E)"
# Every AOT test leaves a 10-15 MB binary in $build/test/aot-e2e/<suite>/aot-bin, about 20 GB in
# all; a disk that fills part way fails hundreds of tests with misleading compile errors.
rm -rf "$build"/test/aot-e2e/*/aot-bin
free_kb=$(df -Pk "$build" | awk 'NR==2 {print $4}')
if [ "$free_kb" -lt $((25 * 1024 * 1024)) ]; then
  echo "upgrade-gates: Gate B needs about 25 GB free for its binaries; $((free_kb / 1024 / 1024)) GB is free"
  exit 1
fi
set +e
cmake --build "$build" --target run-aot-e2e > "$log.aot-e2e" 2>&1
rc=$?
set -e
tail -5 "$log.aot-e2e"
if [ "$rc" -ne 0 ]; then
  unexpected="$(grep -E '^FAIL ' "$log.aot-e2e" | grep -vE 'FlagsRecordTest|PortEchoTest' || true)"
  if [ -n "$unexpected" ]; then
    echo "upgrade-gates: unexpected AOT E2E failures:"; echo "$unexpected"; exit 1
  fi
  echo "OK: AOT E2E (only FlagsRecordTest and PortEchoTest failed, as known)"
fi

step "all gates passed"
