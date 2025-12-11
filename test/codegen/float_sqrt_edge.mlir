// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test eco.float.sqrt with edge cases.

module {
  func.func @main() -> i64 {
    %zero_f = arith.constant 0.0 : f64
    %one = arith.constant 1.0 : f64
    %four = arith.constant 4.0 : f64
    %neg_one = arith.constant -1.0 : f64
    %neg_four = arith.constant -4.0 : f64

    // sqrt(0) = 0
    %sqrt_zero = eco.float.sqrt %zero_f : f64
    %is_zero = eco.float.cmp eq %sqrt_zero, %zero_f : f64
    %is_zero_ext = arith.extui %is_zero : i1 to i64
    eco.dbg %is_zero_ext : i64
    // CHECK: 1

    // sqrt(1) = 1
    %sqrt_one = eco.float.sqrt %one : f64
    %is_one = eco.float.cmp eq %sqrt_one, %one : f64
    %is_one_ext = arith.extui %is_one : i1 to i64
    eco.dbg %is_one_ext : i64
    // CHECK: 1

    // sqrt(4) = 2
    %sqrt_four = eco.float.sqrt %four : f64
    %two = arith.constant 2.0 : f64
    %is_two = eco.float.cmp eq %sqrt_four, %two : f64
    %is_two_ext = arith.extui %is_two : i1 to i64
    eco.dbg %is_two_ext : i64
    // CHECK: 1

    // sqrt(-1) = NaN
    %sqrt_neg = eco.float.sqrt %neg_one : f64
    // NaN != NaN (ordered comparison)
    %is_nan = eco.float.cmp ne %sqrt_neg, %sqrt_neg : f64
    // For ordered NE (ONE), NaN comparisons return false
    // So we check if it equals itself - NaN != NaN is false with OEQ
    %eq_self = eco.float.cmp eq %sqrt_neg, %sqrt_neg : f64
    %not_eq_self = arith.extui %eq_self : i1 to i64
    eco.dbg %not_eq_self : i64
    // CHECK: 0

    // sqrt(-4) = NaN
    %sqrt_neg4 = eco.float.sqrt %neg_four : f64
    %eq_self2 = eco.float.cmp eq %sqrt_neg4, %sqrt_neg4 : f64
    %not_eq_self2 = arith.extui %eq_self2 : i1 to i64
    eco.dbg %not_eq_self2 : i64
    // CHECK: 0

    // Create infinity via 1/0
    %inf = eco.float.div %one, %zero_f : f64
    // sqrt(inf) = inf
    %sqrt_inf = eco.float.sqrt %inf : f64
    %is_inf = eco.float.cmp eq %sqrt_inf, %inf : f64
    %is_inf_ext = arith.extui %is_inf : i1 to i64
    eco.dbg %is_inf_ext : i64
    // CHECK: 1

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
