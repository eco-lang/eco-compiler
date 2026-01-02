// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test eco.bool.not operation.

module {
  func.func @main() -> i64 {
    %true = arith.constant true
    %false = arith.constant false

    // not(true) = false
    %not_true = eco.bool.not %true : i1
    %boxed1 = eco.box %not_true : i1 -> !eco.value
    eco.dbg %boxed1 : !eco.value
    // CHECK: False

    // not(false) = true
    %not_false = eco.bool.not %false : i1
    %boxed2 = eco.box %not_false : i1 -> !eco.value
    eco.dbg %boxed2 : !eco.value
    // CHECK: True

    // Double negation: not(not(true)) = true
    %double_neg = eco.bool.not %not_true : i1
    %boxed3 = eco.box %double_neg : i1 -> !eco.value
    eco.dbg %boxed3 : !eco.value
    // CHECK: True

    // Double negation: not(not(false)) = false
    %double_neg2 = eco.bool.not %not_false : i1
    %boxed4 = eco.box %double_neg2 : i1 -> !eco.value
    eco.dbg %boxed4 : !eco.value
    // CHECK: False

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
