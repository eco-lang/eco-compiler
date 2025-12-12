// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
// XFAIL: *
//
// Test that eco.free compiles as a no-op in GC mode.
// This is a placeholder operation for potential Perceus-style memory management.
// NOTE: eco.free may not be implemented in lowering yet, hence XFAIL.

module {
  func.func @main() -> i64 {
    %c42 = arith.constant 42 : i64
    %boxed = eco.box %c42 : i64 -> !eco.value

    // Free should be a no-op - value still usable
    eco.free %boxed

    // Value should still be accessible after free (GC mode)
    %unboxed = eco.unbox %boxed : !eco.value -> i64
    eco.dbg %unboxed : i64
    // CHECK: [eco.dbg] 42

    // Multiple frees should be fine (no-op)
    eco.free %boxed
    eco.free %boxed

    // Still accessible
    %unboxed2 = eco.unbox %boxed : !eco.value -> i64
    eco.dbg %unboxed2 : i64
    // CHECK: [eco.dbg] 42

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
