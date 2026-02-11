// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test eco.int.toFloat with large integers that lose precision.
// IEEE 754 double has 53 bits of mantissa, so integers > 2^53 may lose precision.

module {
  func.func @main() -> i64 {
    // Small integers convert exactly
    %i100 = arith.constant 100 : i64
    %f100 = eco.int.toFloat %i100 : i64 -> f64
    eco.dbg %f100 : f64
    // CHECK: 100

    // 2^53 = 9007199254740992 - largest integer that converts exactly
    %i_2_53 = arith.constant 9007199254740992 : i64
    %f_2_53 = eco.int.toFloat %i_2_53 : i64 -> f64
    eco.dbg %f_2_53 : f64
    // CHECK: 9007199254740992

    // 2^53 + 1 - this loses precision (rounds to 2^53)
    %i_2_53_plus_1 = arith.constant 9007199254740993 : i64
    %f_2_53_plus_1 = eco.int.toFloat %i_2_53_plus_1 : i64 -> f64
    // May print as same value due to precision loss
    eco.dbg %f_2_53_plus_1 : f64
    // CHECK: 9007199254740992

    // Very large integer
    %i_large = arith.constant 1000000000000000000 : i64
    %f_large = eco.int.toFloat %i_large : i64 -> f64
    eco.dbg %f_large : f64
    // CHECK: 1e+18

    // Negative large integer
    %i_neg_large = arith.constant -1000000000000000000 : i64
    %f_neg_large = eco.int.toFloat %i_neg_large : i64 -> f64
    eco.dbg %f_neg_large : f64
    // CHECK: -1e+18

    // INT64_MAX
    %i_max = arith.constant 9223372036854775807 : i64
    %f_max = eco.int.toFloat %i_max : i64 -> f64
    eco.dbg %f_max : f64
    // CHECK: 9223372036854775808

    // INT64_MIN
    %i_min = arith.constant -9223372036854775808 : i64
    %f_min = eco.int.toFloat %i_min : i64 -> f64
    eco.dbg %f_min : f64
    // CHECK: -9223372036854775808

    // Zero
    %i_zero = arith.constant 0 : i64
    %f_zero = eco.int.toFloat %i_zero : i64 -> f64
    eco.dbg %f_zero : f64
    // CHECK: 0

    // -1
    %i_neg1 = arith.constant -1 : i64
    %f_neg1 = eco.int.toFloat %i_neg1 : i64 -> f64
    eco.dbg %f_neg1 : f64
    // CHECK: -1

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
