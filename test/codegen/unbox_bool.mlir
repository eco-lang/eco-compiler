// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test eco.unbox to i1 (Bool) - currently crashes.
// The UnboxOpLowering doesn't handle i1 result type properly.

module {
  func.func @main() -> i64 {
    // Box a boolean true
    %true_val = arith.constant true
    %boxed_true = eco.box %true_val : i1 -> !eco.value

    // Attempt to unbox back to i1 - THIS CRASHES
    %unboxed = eco.unbox %boxed_true : !eco.value -> i1

    // If it worked, we'd convert to i64 and print
    %as_i64 = arith.extui %unboxed : i1 to i64
    eco.dbg %as_i64 : i64
    // CHECK: 1

    // Test false
    %false_val = arith.constant false
    %boxed_false = eco.box %false_val : i1 -> !eco.value
    %unboxed_false = eco.unbox %boxed_false : !eco.value -> i1
    %as_i64_f = arith.extui %unboxed_false : i1 to i64
    eco.dbg %as_i64_f : i64
    // CHECK: 0

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
