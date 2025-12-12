// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test eco.float.floor with various values.
// floor(x) returns the largest integer <= x (as i64).

module {
  func.func @main() -> i64 {
    // Positive fractional: floor(3.7) = 3
    %f3_7 = arith.constant 3.7 : f64
    %floor1 = eco.float.floor %f3_7 : f64 -> i64
    eco.dbg %floor1 : i64
    // CHECK: [eco.dbg] 3

    // Negative fractional: floor(-3.7) = -4 (NOT -3)
    %fn3_7 = arith.constant -3.7 : f64
    %floor2 = eco.float.floor %fn3_7 : f64 -> i64
    eco.dbg %floor2 : i64
    // CHECK: [eco.dbg] -4

    // Exact integer: floor(5.0) = 5
    %f5 = arith.constant 5.0 : f64
    %floor3 = eco.float.floor %f5 : f64 -> i64
    eco.dbg %floor3 : i64
    // CHECK: [eco.dbg] 5

    // Exact negative integer: floor(-5.0) = -5
    %fn5 = arith.constant -5.0 : f64
    %floor4 = eco.float.floor %fn5 : f64 -> i64
    eco.dbg %floor4 : i64
    // CHECK: [eco.dbg] -5

    // Small positive: floor(0.1) = 0
    %f0_1 = arith.constant 0.1 : f64
    %floor5 = eco.float.floor %f0_1 : f64 -> i64
    eco.dbg %floor5 : i64
    // CHECK: [eco.dbg] 0

    // Small negative: floor(-0.1) = -1
    %fn0_1 = arith.constant -0.1 : f64
    %floor6 = eco.float.floor %fn0_1 : f64 -> i64
    eco.dbg %floor6 : i64
    // CHECK: [eco.dbg] -1

    // Zero: floor(0.0) = 0
    %f0 = arith.constant 0.0 : f64
    %floor7 = eco.float.floor %f0 : f64 -> i64
    eco.dbg %floor7 : i64
    // CHECK: [eco.dbg] 0

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
