// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test floor/ceiling with special floating-point values.
// Note: floor/ceiling return i64, so special float values get truncated.

module {
  func.func @main() -> i64 {
    %neg_zero = arith.constant -0.0 : f64

    // floor(-0.0) should be 0
    %floor_neg_zero = eco.float.floor %neg_zero : f64 -> i64
    eco.dbg %floor_neg_zero : i64
    // CHECK: [eco.dbg] 0

    // ceiling(-0.0) should be 0
    %ceil_neg_zero = eco.float.ceiling %neg_zero : f64 -> i64
    eco.dbg %ceil_neg_zero : i64
    // CHECK: [eco.dbg] 0

    // Test with positive zero
    %pos_zero = arith.constant 0.0 : f64
    %floor_zero = eco.float.floor %pos_zero : f64 -> i64
    eco.dbg %floor_zero : i64
    // CHECK: [eco.dbg] 0

    %ceil_zero = eco.float.ceiling %pos_zero : f64 -> i64
    eco.dbg %ceil_zero : i64
    // CHECK: [eco.dbg] 0

    // Test floor/ceiling with values near boundaries
    %almost_one = arith.constant 0.999999 : f64
    %floor_almost = eco.float.floor %almost_one : f64 -> i64
    eco.dbg %floor_almost : i64
    // CHECK: [eco.dbg] 0

    %ceil_almost = eco.float.ceiling %almost_one : f64 -> i64
    eco.dbg %ceil_almost : i64
    // CHECK: [eco.dbg] 1

    // Negative almost one
    %neg_almost = arith.constant -0.999999 : f64
    %floor_neg_almost = eco.float.floor %neg_almost : f64 -> i64
    eco.dbg %floor_neg_almost : i64
    // CHECK: [eco.dbg] -1

    %ceil_neg_almost = eco.float.ceiling %neg_almost : f64 -> i64
    eco.dbg %ceil_neg_almost : i64
    // CHECK: [eco.dbg] 0

    // Large values within i64 range
    %large = arith.constant 1000000000.5 : f64
    %floor_large = eco.float.floor %large : f64 -> i64
    eco.dbg %floor_large : i64
    // CHECK: [eco.dbg] 1000000000

    %ceil_large = eco.float.ceiling %large : f64 -> i64
    eco.dbg %ceil_large : i64
    // CHECK: [eco.dbg] 1000000001

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
