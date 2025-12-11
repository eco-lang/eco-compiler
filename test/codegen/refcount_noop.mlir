// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
// XFAIL: *
//
// Test that reference counting operations are no-ops in GC mode.
// These operations are placeholders for potential Perceus-style memory management.
// In the current tracing GC implementation, they should be eliminated or be no-ops.
//
// NOTE: These ops may not be implemented in the lowering yet, hence XFAIL.

module {
  func.func @main() -> i64 {
    %c42 = arith.constant 42 : i64
    %boxed = eco.box %c42 : i64 -> !eco.value

    // These should all be no-ops in GC mode
    eco.incref %boxed {amount = 1 : i64}
    eco.incref %boxed {amount = 5 : i64}
    eco.decref %boxed
    eco.decref_shallow %boxed

    // Value should still be accessible
    %unboxed = eco.unbox %boxed : !eco.value -> i64
    eco.dbg %unboxed : i64
    // CHECK: 42

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
