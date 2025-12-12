// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test eco.float.ceiling with various values.
// ceiling(x) returns the smallest integer >= x (as i64).

module {
  func.func @main() -> i64 {
    // Positive fractional: ceiling(3.2) = 4
    %f3_2 = arith.constant 3.2 : f64
    %ceil1 = eco.float.ceiling %f3_2 : f64 -> i64
    eco.dbg %ceil1 : i64
    // CHECK: [eco.dbg] 4

    // Negative fractional: ceiling(-3.2) = -3 (NOT -4)
    %fn3_2 = arith.constant -3.2 : f64
    %ceil2 = eco.float.ceiling %fn3_2 : f64 -> i64
    eco.dbg %ceil2 : i64
    // CHECK: [eco.dbg] -3

    // Exact integer: ceiling(5.0) = 5
    %f5 = arith.constant 5.0 : f64
    %ceil3 = eco.float.ceiling %f5 : f64 -> i64
    eco.dbg %ceil3 : i64
    // CHECK: [eco.dbg] 5

    // Exact negative integer: ceiling(-5.0) = -5
    %fn5 = arith.constant -5.0 : f64
    %ceil4 = eco.float.ceiling %fn5 : f64 -> i64
    eco.dbg %ceil4 : i64
    // CHECK: [eco.dbg] -5

    // Small positive: ceiling(0.1) = 1
    %f0_1 = arith.constant 0.1 : f64
    %ceil5 = eco.float.ceiling %f0_1 : f64 -> i64
    eco.dbg %ceil5 : i64
    // CHECK: [eco.dbg] 1

    // Small negative: ceiling(-0.1) = 0
    %fn0_1 = arith.constant -0.1 : f64
    %ceil6 = eco.float.ceiling %fn0_1 : f64 -> i64
    eco.dbg %ceil6 : i64
    // CHECK: [eco.dbg] 0

    // Zero: ceiling(0.0) = 0
    %f0 = arith.constant 0.0 : f64
    %ceil7 = eco.float.ceiling %f0 : f64 -> i64
    eco.dbg %ceil7 : i64
    // CHECK: [eco.dbg] 0

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
