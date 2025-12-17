// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test eco.float.pow edge cases.

module {
  func.func @main() -> i64 {
    %zero_f = arith.constant 0.0 : f64
    %one = arith.constant 1.0 : f64
    %two = arith.constant 2.0 : f64
    %neg_one = arith.constant -1.0 : f64
    %neg_two = arith.constant -2.0 : f64
    %half = arith.constant 0.5 : f64
    %ten = arith.constant 10.0 : f64

    // 0.0^0.0 = 1.0 (IEEE 754)
    %pow_0_0 = eco.float.pow %zero_f, %zero_f : f64
    %is_one = eco.float.eq %pow_0_0, %one : f64
    %is_one_ext = arith.extui %is_one : i1 to i64
    eco.dbg %is_one_ext : i64
    // CHECK: 1

    // x^0 = 1 for any finite x
    %pow_2_0 = eco.float.pow %two, %zero_f : f64
    %is_one2 = eco.float.eq %pow_2_0, %one : f64
    %is_one2_ext = arith.extui %is_one2 : i1 to i64
    eco.dbg %is_one2_ext : i64
    // CHECK: 1

    // 1^x = 1 for any x
    %pow_1_10 = eco.float.pow %one, %ten : f64
    %is_one3 = eco.float.eq %pow_1_10, %one : f64
    %is_one3_ext = arith.extui %is_one3 : i1 to i64
    eco.dbg %is_one3_ext : i64
    // CHECK: 1

    // 2^0.5 = sqrt(2) approx 1.414
    %sqrt2 = eco.float.pow %two, %half : f64
    %sqrt2_lower = arith.constant 1.41 : f64
    %sqrt2_upper = arith.constant 1.42 : f64
    %sqrt2_ok_lower = eco.float.gt %sqrt2, %sqrt2_lower : f64
    %sqrt2_ok_upper = eco.float.lt %sqrt2, %sqrt2_upper : f64
    %sqrt2_ok = arith.andi %sqrt2_ok_lower, %sqrt2_ok_upper : i1
    %sqrt2_ok_ext = arith.extui %sqrt2_ok : i1 to i64
    eco.dbg %sqrt2_ok_ext : i64
    // CHECK: 1

    // (-2)^2 = 4 (even integer exponent)
    %pow_neg2_2 = eco.float.pow %neg_two, %two : f64
    %four = arith.constant 4.0 : f64
    %is_four = eco.float.eq %pow_neg2_2, %four : f64
    %is_four_ext = arith.extui %is_four : i1 to i64
    eco.dbg %is_four_ext : i64
    // CHECK: 1

    // (-2)^0.5 = NaN (non-integer exponent of negative base)
    %pow_neg2_half = eco.float.pow %neg_two, %half : f64
    %is_nan = eco.float.eq %pow_neg2_half, %pow_neg2_half : f64
    %is_nan_ext = arith.extui %is_nan : i1 to i64
    eco.dbg %is_nan_ext : i64
    // CHECK: 0

    // Create infinity
    %inf = eco.float.div %one, %zero_f : f64

    // inf^0 = 1
    %pow_inf_0 = eco.float.pow %inf, %zero_f : f64
    %inf_pow_is_one = eco.float.eq %pow_inf_0, %one : f64
    %inf_pow_is_one_ext = arith.extui %inf_pow_is_one : i1 to i64
    eco.dbg %inf_pow_is_one_ext : i64
    // CHECK: 1

    // 2^(-1) = 0.5
    %pow_2_neg1 = eco.float.pow %two, %neg_one : f64
    %is_half = eco.float.eq %pow_2_neg1, %half : f64
    %is_half_ext = arith.extui %is_half : i1 to i64
    eco.dbg %is_half_ext : i64
    // CHECK: 1

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
