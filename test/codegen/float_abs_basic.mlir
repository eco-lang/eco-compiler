// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test eco.float.abs with various values.

module {
  func.func @main() -> i64 {
    // abs(positive) = positive
    %f5 = arith.constant 5.5 : f64
    %abs1 = eco.float.abs %f5 : f64
    %eq1 = eco.float.cmp eq %abs1, %f5 : f64
    %eq1_i = arith.extui %eq1 : i1 to i64
    eco.dbg %eq1_i : i64
    // CHECK: [eco.dbg] 1

    // abs(negative) = positive
    %fn5 = arith.constant -5.5 : f64
    %abs2 = eco.float.abs %fn5 : f64
    %eq2 = eco.float.cmp eq %abs2, %f5 : f64
    %eq2_i = arith.extui %eq2 : i1 to i64
    eco.dbg %eq2_i : i64
    // CHECK: [eco.dbg] 1

    // abs(0.0) = 0.0
    %f0 = arith.constant 0.0 : f64
    %abs3 = eco.float.abs %f0 : f64
    %eq3 = eco.float.cmp eq %abs3, %f0 : f64
    %eq3_i = arith.extui %eq3 : i1 to i64
    eco.dbg %eq3_i : i64
    // CHECK: [eco.dbg] 1

    // abs(-0.0) = 0.0 (positive zero)
    %fn0 = arith.constant -0.0 : f64
    %abs4 = eco.float.abs %fn0 : f64
    %eq4 = eco.float.cmp eq %abs4, %f0 : f64
    %eq4_i = arith.extui %eq4 : i1 to i64
    eco.dbg %eq4_i : i64
    // CHECK: [eco.dbg] 1

    // abs(+Inf) = +Inf
    %one = arith.constant 1.0 : f64
    %pos_inf = arith.divf %one, %f0 : f64
    %abs5 = eco.float.abs %pos_inf : f64
    %million = arith.constant 1000000.0 : f64
    %huge = eco.float.cmp gt %abs5, %million : f64
    %huge_i = arith.extui %huge : i1 to i64
    eco.dbg %huge_i : i64
    // CHECK: [eco.dbg] 1

    // abs(-Inf) = +Inf
    %neg_inf = arith.negf %pos_inf : f64
    %abs6 = eco.float.abs %neg_inf : f64
    %huge2 = eco.float.cmp gt %abs6, %million : f64
    %huge2_i = arith.extui %huge2 : i1 to i64
    eco.dbg %huge2_i : i64
    // CHECK: [eco.dbg] 1

    // abs(NaN) = NaN (still NaN)
    %nan = arith.divf %f0, %f0 : f64
    %abs7 = eco.float.abs %nan : f64
    %nan_eq = eco.float.cmp eq %abs7, %abs7 : f64
    %nan_eq_i = arith.extui %nan_eq : i1 to i64
    eco.dbg %nan_eq_i : i64
    // CHECK: [eco.dbg] 0

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
