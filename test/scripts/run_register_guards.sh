#!/bin/sh
# Runs every guard of the concurrency register (plans/threaded-gc-concurrency-register.md;
# plans/threaded-gc-register-repros-impl.md §13.6) and reports each step, continuing after a
# failing step so the whole list is shown. Called by the register-guards CMake target.
#
#   run_register_guards.sh <test-exe> <validate-dir> <source-dir> <cmake> <cc> <cxx> <fork-build-dir>
#
# Steps:
#   1. unit guards              <test-exe> --filter "CR-0": every register guard -- the xfail
#                               ones, the fixed ones (plans/threaded-gc-register-fixes.md: a
#                               converted guard must keep passing), won't-fix ones and controls
#   2. validate-only guards     CR-028 and CR-036 (IM5) in <validate-dir> (configured with
#                               ECO_HEAP_VALIDATE=ON if it has no cache), built and run
#   3. harness arms             run_fork_arms.py --tier quick: fork (plain), trace (det-*), TSan
#
# Default mode: a reproduced defect is XFAIL (passes); a guard whose defect has gone is XPASS
# (fails: flip it to a fixed guard). ECO_TEST_XFAIL=strict: every reproduced defect fails, so the
# target is red until every open register defect is fixed.
set -u
test_exe=$1 vdir=$2 src=$3 cmake=$4 cc=$5 cxx=$6 forkdir=$7
ulimit -c 0
mode=${ECO_TEST_XFAIL:-default}
fail=0
results=""

step() {   # step <name> <command...>
    name=$1; shift
    echo "==== register-guards: $name"
    if "$@"; then r=ok; else r=FAILED; fail=1; fi
    results="$results
  $r  $name"
}

step "unit guards, xfail and fixed (build)" "$test_exe" --filter "CR-0"

configure_validate() {
    [ -f "$vdir/CMakeCache.txt" ] && return 0
    "$cmake" -S "$src" -B "$vdir" -G Ninja -DCMAKE_BUILD_TYPE=RelWithDebInfo \
        "-DCMAKE_CXX_FLAGS_RELWITHDEBINFO=-O2 -g -UNDEBUG" -DECO_HEAP_VALIDATE=ON \
        "-DCMAKE_C_COMPILER=$cc" "-DCMAKE_CXX_COMPILER=$cxx"
}
validate_guards() {
    configure_validate || return 1
    grep -q '^ECO_HEAP_VALIDATE:BOOL=ON' "$vdir/CMakeCache.txt" || {
        echo "register-guards: $vdir is not an ECO_HEAP_VALIDATE=ON tree"; return 1; }
    "$cmake" --build "$vdir" --target test || return 1
    vrc=0
    "$vdir/test/test" --filter "CR-028" || vrc=1   # run both even when one fails (strict)
    "$vdir/test/test" --filter "CR-036" || vrc=1
    return $vrc
}
step "validate-only guards (CR-028, CR-036, $vdir)" validate_guards

step "harness arms (fork, trace, TSan)" python3 "$src/test/gc-heap-tsan/run_fork_arms.py" \
    --tier quick "--build-dir=$forkdir"

echo "==== register-guards summary (ECO_TEST_XFAIL=$mode):$results"
if [ "$fail" -ne 0 ]; then
    if [ "$mode" = strict ]; then
        echo "register-guards: RED - open register defects reproduce (expected until they are fixed)"
    else
        echo "register-guards: FAILED - a guard XPASSed (flip it), missed its precondition, or errored"
    fi
fi
exit "$fail"
