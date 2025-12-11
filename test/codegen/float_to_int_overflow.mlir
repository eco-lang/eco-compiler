// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test float-to-int conversions with values that may overflow.
// Behavior is implementation-defined for out-of-range values.

module {
  func.func @main() -> i64 {
    // Test with values within i64 range first
    %f_max_safe = arith.constant 9007199254740992.0 : f64  // 2^53 (max exact integer in f64)
    %f_neg_safe = arith.constant -9007199254740992.0 : f64

    // round of max safe integer
    %round_max = eco.float.round %f_max_safe : f64 -> i64
    eco.dbg %round_max : i64
    // CHECK: 9007199254740992

    // floor of negative safe integer
    %floor_neg = eco.float.floor %f_neg_safe : f64 -> i64
    eco.dbg %floor_neg : i64
    // CHECK: -9007199254740992

    // Test with fractional values near boundaries
    %f_half = arith.constant 0.5 : f64
    %round_half = eco.float.round %f_half : f64 -> i64
    eco.dbg %round_half : i64
    // CHECK: 1

    %neg_half = arith.constant -0.5 : f64
    %round_neg_half = eco.float.round %neg_half : f64 -> i64
    eco.dbg %round_neg_half : i64
    // CHECK: -1

    // truncate toward zero
    %f_2_9 = arith.constant 2.9 : f64
    %trunc_pos = eco.float.truncate %f_2_9 : f64 -> i64
    eco.dbg %trunc_pos : i64
    // CHECK: 2

    %neg_2_9 = arith.constant -2.9 : f64
    %trunc_neg = eco.float.truncate %neg_2_9 : f64 -> i64
    eco.dbg %trunc_neg : i64
    // CHECK: -2

    // ceiling
    %ceil_pos = eco.float.ceiling %f_2_9 : f64 -> i64
    eco.dbg %ceil_pos : i64
    // CHECK: 3

    %ceil_neg = eco.float.ceiling %neg_2_9 : f64 -> i64
    eco.dbg %ceil_neg : i64
    // CHECK: -2

    // floor
    %floor_pos = eco.float.floor %f_2_9 : f64 -> i64
    eco.dbg %floor_pos : i64
    // CHECK: 2

    %floor_neg2 = eco.float.floor %neg_2_9 : f64 -> i64
    eco.dbg %floor_neg2 : i64
    // CHECK: -3

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
