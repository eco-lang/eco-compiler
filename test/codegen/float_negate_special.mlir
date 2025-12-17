// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test eco.float.negate with special values.

module {
  func.func @main() -> i64 {
    %f0 = arith.constant 0.0 : f64
    %one = arith.constant 1.0 : f64

    // negate(positive) = negative
    %f5 = arith.constant 5.0 : f64
    %neg5 = eco.float.negate %f5 : f64
    %expected_n5 = arith.constant -5.0 : f64
    %eq1 = eco.float.eq %neg5, %expected_n5 : f64
    %eq1_i = arith.extui %eq1 : i1 to i64
    eco.dbg %eq1_i : i64
    // CHECK: [eco.dbg] 1

    // negate(negative) = positive
    %fn3 = arith.constant -3.0 : f64
    %neg_neg3 = eco.float.negate %fn3 : f64
    %expected_3 = arith.constant 3.0 : f64
    %eq2 = eco.float.eq %neg_neg3, %expected_3 : f64
    %eq2_i = arith.extui %eq2 : i1 to i64
    eco.dbg %eq2_i : i64
    // CHECK: [eco.dbg] 1

    // negate(0.0) = -0.0
    // Test by dividing: 1 / -0 = -Inf
    %neg_zero = eco.float.negate %f0 : f64
    %div_neg_zero = arith.divf %one, %neg_zero : f64
    %neg_million = arith.constant -1000000.0 : f64
    %is_neg_inf = eco.float.lt %div_neg_zero, %neg_million : f64
    %is_neg_inf_i = arith.extui %is_neg_inf : i1 to i64
    eco.dbg %is_neg_inf_i : i64
    // CHECK: [eco.dbg] 1

    // negate(-0.0) = +0.0
    // Test by dividing: 1 / +0 = +Inf
    %neg_neg_zero = arith.constant -0.0 : f64
    %pos_zero = eco.float.negate %neg_neg_zero : f64
    %div_pos_zero = arith.divf %one, %pos_zero : f64
    %million = arith.constant 1000000.0 : f64
    %is_pos_inf = eco.float.gt %div_pos_zero, %million : f64
    %is_pos_inf_i = arith.extui %is_pos_inf : i1 to i64
    eco.dbg %is_pos_inf_i : i64
    // CHECK: [eco.dbg] 1

    // negate(+Inf) = -Inf
    %pos_inf = arith.divf %one, %f0 : f64
    %neg_inf = eco.float.negate %pos_inf : f64
    %is_very_neg = eco.float.lt %neg_inf, %neg_million : f64
    %is_very_neg_i = arith.extui %is_very_neg : i1 to i64
    eco.dbg %is_very_neg_i : i64
    // CHECK: [eco.dbg] 1

    // negate(-Inf) = +Inf
    %neg_inf2 = arith.negf %pos_inf : f64
    %pos_inf2 = eco.float.negate %neg_inf2 : f64
    %is_very_pos = eco.float.gt %pos_inf2, %million : f64
    %is_very_pos_i = arith.extui %is_very_pos : i1 to i64
    eco.dbg %is_very_pos_i : i64
    // CHECK: [eco.dbg] 1

    // negate(NaN) = NaN
    %nan = arith.divf %f0, %f0 : f64
    %neg_nan = eco.float.negate %nan : f64
    %nan_eq = eco.float.eq %neg_nan, %neg_nan : f64
    %nan_eq_i = arith.extui %nan_eq : i1 to i64
    eco.dbg %nan_eq_i : i64
    // CHECK: [eco.dbg] 0

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
