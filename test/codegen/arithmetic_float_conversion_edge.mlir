// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test toFloat and conversion functions with edge cases.

module {
  func.func @main() -> i64 {
    // Large integer conversion
    %max_exact = arith.constant 9007199254740992 : i64
    %max_float = eco.int.toFloat %max_exact : i64 -> f64
    eco.dbg %max_float : f64
    // CHECK: 9.0072e+15

    // toFloat(0) = 0.0
    %i0 = arith.constant 0 : i64
    %f_zero = eco.int.toFloat %i0 : i64 -> f64
    eco.dbg %f_zero : f64
    // CHECK: 0

    // toFloat(-1) = -1.0
    %neg1 = arith.constant -1 : i64
    %f_neg1 = eco.int.toFloat %neg1 : i64 -> f64
    eco.dbg %f_neg1 : f64
    // CHECK: -1

    // Create special floats
    %f0 = arith.constant 0.0 : f64
    %f1 = arith.constant 1.0 : f64
    %neg1f = arith.constant -1.0 : f64
    %nan = arith.divf %f0, %f0 : f64
    %pos_inf = eco.float.div %f1, %f0 : f64
    %neg_inf = eco.float.div %neg1f, %f0 : f64

    // round(+Inf) - undefined behavior, just test it doesn't crash
    // The result is implementation-defined
    %round_inf = eco.float.round %pos_inf : f64 -> i64
    eco.dbg %round_inf : i64
    // CHECK: -9223372036854775808

    // floor(+Inf)
    %floor_inf = eco.float.floor %pos_inf : f64 -> i64
    eco.dbg %floor_inf : i64
    // CHECK: -9223372036854775808

    // ceiling(-Inf)
    %ceil_neg_inf = eco.float.ceiling %neg_inf : f64 -> i64
    eco.dbg %ceil_neg_inf : i64
    // CHECK: -9223372036854775808

    // truncate(NaN)
    %trunc_nan = eco.float.truncate %nan : f64 -> i64
    eco.dbg %trunc_nan : i64
    // CHECK: -9223372036854775808

    // round(0.5) = 1 (round half to even or away from zero)
    %f0_5 = arith.constant 0.5 : f64
    %round_half = eco.float.round %f0_5 : f64 -> i64
    eco.dbg %round_half : i64
    // CHECK: 1

    // round(-0.5) = -1
    %neg0_5 = arith.constant -0.5 : f64
    %round_neg_half = eco.float.round %neg0_5 : f64 -> i64
    eco.dbg %round_neg_half : i64
    // CHECK: -1

    // floor(0.9) = 0
    %f0_9 = arith.constant 0.9 : f64
    %floor_09 = eco.float.floor %f0_9 : f64 -> i64
    eco.dbg %floor_09 : i64
    // CHECK: 0

    // ceiling(0.1) = 1
    %f0_1 = arith.constant 0.1 : f64
    %ceil_01 = eco.float.ceiling %f0_1 : f64 -> i64
    eco.dbg %ceil_01 : i64
    // CHECK: 1

    // truncate(-0.9) = 0 (towards zero)
    %neg0_9 = arith.constant -0.9 : f64
    %trunc_neg = eco.float.truncate %neg0_9 : f64 -> i64
    eco.dbg %trunc_neg : i64
    // CHECK: 0

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
