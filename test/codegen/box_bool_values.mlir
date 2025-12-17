// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test eco.box with i1 (Bool) values - boxing true and false.
// Note: Boxed bools use a special runtime representation (True/False constants)
// and don't support unboxing back to i64.

module {
  func.func @main() -> i64 {
    // Create bool values
    %true_val = arith.constant true
    %false_val = arith.constant false

    // Box true - should display as "True"
    %boxed_true = eco.box %true_val : i1 -> !eco.value
    eco.dbg %boxed_true : !eco.value
    // CHECK: True

    // Box false - should display as "False"
    %boxed_false = eco.box %false_val : i1 -> !eco.value
    eco.dbg %boxed_false : !eco.value
    // CHECK: False

    // Use boxed bools in comparisons that produce bools, then box result
    %i5 = arith.constant 5 : i64
    %i10 = arith.constant 10 : i64
    %cmp_lt = eco.int.lt %i5, %i10 : i64
    %boxed_cmp = eco.box %cmp_lt : i1 -> !eco.value
    eco.dbg %boxed_cmp : !eco.value
    // CHECK: True

    %cmp_gt = eco.int.gt %i5, %i10 : i64
    %boxed_cmp2 = eco.box %cmp_gt : i1 -> !eco.value
    eco.dbg %boxed_cmp2 : !eco.value
    // CHECK: False

    // Box result of float comparison
    %f1 = arith.constant 1.5 : f64
    %f2 = arith.constant 2.5 : f64
    %fcmp = eco.float.le %f1, %f2 : f64
    %boxed_fcmp = eco.box %fcmp : i1 -> !eco.value
    eco.dbg %boxed_fcmp : !eco.value
    // CHECK: True

    // Box equality check result
    %eq = eco.float.eq %f1, %f1 : f64
    %boxed_eq = eco.box %eq : i1 -> !eco.value
    eco.dbg %boxed_eq : !eco.value
    // CHECK: True

    // Box inequality check result
    %ne = eco.float.ne %f1, %f1 : f64
    %boxed_ne = eco.box %ne : i1 -> !eco.value
    eco.dbg %boxed_ne : !eco.value
    // CHECK: False

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
