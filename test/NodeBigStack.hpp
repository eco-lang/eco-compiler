#pragma once

// Shell script (for `sh -c SCRIPT sh ARGS...`) that runs `node ARGS...` with the deepest stack
// the OS allows. The Stage-1 JS compiler recurses deeply on very wide programs (arity-2047
// closures, 1100-field records) and otherwise overflows
// (plans/wide-object-tail-kind-words-phase-0.md step 0.5).
//
// It raises the soft stack limit to unlimited, or to the hard limit where unlimited is refused
// (macOS caps the stack at 64 MiB), then gives V8 90 % of whatever limit is in force, at most
// 500000 KiB. Telling V8 it may use more stack than the process has makes it recurse past the
// real stack and die with SIGSEGV instead of a RangeError (macOS: an 8 MiB soft limit under
// --stack-size=500000).
inline constexpr const char* kNodeBigStackScript =
    "ulimit -s unlimited 2>/dev/null || ulimit -s \"$(ulimit -H -s)\" 2>/dev/null; "
    "s=$(ulimit -s); k=500000; "
    "if [ \"$s\" != unlimited ] && [ $((s / 10 * 9)) -lt $k ]; then k=$((s / 10 * 9)); fi; "
    "exec node --stack-size=$k \"$@\"";
