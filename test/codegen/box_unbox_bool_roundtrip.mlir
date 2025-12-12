// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test box i1 -> unbox -> compare roundtrip.
// Boolean uses embedded constants, needs verification.

module {
  func.func @main() -> i64 {
    // Box true
    %true_val = arith.constant true
    %boxed_true = eco.box %true_val : i1 -> !eco.value

    // Unbox back
    %unboxed_true = eco.unbox %boxed_true : !eco.value -> i1

    // Verify it's still true
    %true_check = arith.extui %unboxed_true : i1 to i64
    eco.dbg %true_check : i64
    // CHECK: [eco.dbg] 1

    // Box false
    %false_val = arith.constant false
    %boxed_false = eco.box %false_val : i1 -> !eco.value

    // Unbox back
    %unboxed_false = eco.unbox %boxed_false : !eco.value -> i1

    // Verify it's still false
    %false_check = arith.extui %unboxed_false : i1 to i64
    eco.dbg %false_check : i64
    // CHECK: [eco.dbg] 0

    // Compare with embedded constants
    %const_true = eco.constant True : !eco.value
    %const_false = eco.constant False : !eco.value

    // Unbox the constants
    %from_const_true = eco.unbox %const_true : !eco.value -> i1
    %from_const_false = eco.unbox %const_false : !eco.value -> i1

    %const_true_i = arith.extui %from_const_true : i1 to i64
    %const_false_i = arith.extui %from_const_false : i1 to i64

    eco.dbg %const_true_i : i64
    eco.dbg %const_false_i : i64
    // CHECK: [eco.dbg] 1
    // CHECK: [eco.dbg] 0

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
