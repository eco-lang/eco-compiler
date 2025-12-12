// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
// XFAIL: *
//
// Test that eco.reset and eco.reset_ref compile as no-ops in GC mode.
// These are placeholder operations for Perceus-style reuse analysis.
// NOTE: These ops may not be implemented in lowering yet, hence XFAIL.

module {
  func.func @main() -> i64 {
    %c42 = arith.constant 42 : i64
    %boxed = eco.box %c42 : i64 -> !eco.value

    // Reset should be a no-op
    eco.reset %boxed

    // Value should still be accessible
    %unboxed = eco.unbox %boxed : !eco.value -> i64
    eco.dbg %unboxed : i64
    // CHECK: [eco.dbg] 42

    // Reset_ref should also be a no-op
    eco.reset_ref %boxed

    // Still accessible
    %unboxed2 = eco.unbox %boxed : !eco.value -> i64
    eco.dbg %unboxed2 : i64
    // CHECK: [eco.dbg] 42

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
