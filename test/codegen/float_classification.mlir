// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test float classification: isNaN and isInfinite

module {
  func.func @main() -> i64 {
    // Create NaN (0.0 / 0.0)
    %zero = arith.constant 0.0 : f64
    %nan = arith.divf %zero, %zero : f64

    // Create infinity (1.0 / 0.0)
    %one = arith.constant 1.0 : f64
    %inf = arith.divf %one, %zero : f64

    // Create negative infinity
    %neg_one = arith.constant -1.0 : f64
    %neg_inf = arith.divf %neg_one, %zero : f64

    // isNaN(NaN) = true
    %is_nan_nan = eco.float.isNaN %nan : f64
    %is_nan_nan_i = arith.extui %is_nan_nan : i1 to i64
    eco.dbg %is_nan_nan_i : i64
    // CHECK: [eco.dbg] 1

    // isNaN(1.0) = false
    %is_nan_one = eco.float.isNaN %one : f64
    %is_nan_one_i = arith.extui %is_nan_one : i1 to i64
    eco.dbg %is_nan_one_i : i64
    // CHECK: [eco.dbg] 0

    // isNaN(inf) = false
    %is_nan_inf = eco.float.isNaN %inf : f64
    %is_nan_inf_i = arith.extui %is_nan_inf : i1 to i64
    eco.dbg %is_nan_inf_i : i64
    // CHECK: [eco.dbg] 0

    // isInfinite(inf) = true
    %is_inf_inf = eco.float.isInfinite %inf : f64
    %is_inf_inf_i = arith.extui %is_inf_inf : i1 to i64
    eco.dbg %is_inf_inf_i : i64
    // CHECK: [eco.dbg] 1

    // isInfinite(-inf) = true
    %is_inf_neg_inf = eco.float.isInfinite %neg_inf : f64
    %is_inf_neg_inf_i = arith.extui %is_inf_neg_inf : i1 to i64
    eco.dbg %is_inf_neg_inf_i : i64
    // CHECK: [eco.dbg] 1

    // isInfinite(1.0) = false
    %is_inf_one = eco.float.isInfinite %one : f64
    %is_inf_one_i = arith.extui %is_inf_one : i1 to i64
    eco.dbg %is_inf_one_i : i64
    // CHECK: [eco.dbg] 0

    // isInfinite(NaN) = false
    %is_inf_nan = eco.float.isInfinite %nan : f64
    %is_inf_nan_i = arith.extui %is_inf_nan : i1 to i64
    eco.dbg %is_inf_nan_i : i64
    // CHECK: [eco.dbg] 0

    %ret = arith.constant 0 : i64
    return %ret : i64
  }
}
