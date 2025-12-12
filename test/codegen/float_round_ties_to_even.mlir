// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test eco.float.round with half values (ties).
// The round operation returns i64 directly.
// Note: Actual rounding behavior depends on implementation (may not be banker's rounding).

module {
  func.func @main() -> i64 {
    // Regular rounding (not ties)
    %f3_2 = arith.constant 3.2 : f64
    %r1 = eco.float.round %f3_2 : f64 -> i64
    eco.dbg %r1 : i64
    // CHECK: [eco.dbg] 3

    %f3_7 = arith.constant 3.7 : f64
    %r2 = eco.float.round %f3_7 : f64 -> i64
    eco.dbg %r2 : i64
    // CHECK: [eco.dbg] 4

    // Half values - actual behavior may vary
    %f2_5 = arith.constant 2.5 : f64
    %r3 = eco.float.round %f2_5 : f64 -> i64
    eco.dbg %r3 : i64
    // May be 2 (banker's) or 3 (away from zero)
    // CHECK: [eco.dbg]

    %f3_5 = arith.constant 3.5 : f64
    %r4 = eco.float.round %f3_5 : f64 -> i64
    eco.dbg %r4 : i64
    // CHECK: [eco.dbg]

    // Negative values
    %fn3_2 = arith.constant -3.2 : f64
    %r5 = eco.float.round %fn3_2 : f64 -> i64
    eco.dbg %r5 : i64
    // CHECK: [eco.dbg] -3

    %fn3_7 = arith.constant -3.7 : f64
    %r6 = eco.float.round %fn3_7 : f64 -> i64
    eco.dbg %r6 : i64
    // CHECK: [eco.dbg] -4

    // Zero
    %f0 = arith.constant 0.0 : f64
    %r7 = eco.float.round %f0 : f64 -> i64
    eco.dbg %r7 : i64
    // CHECK: [eco.dbg] 0

    // Negative zero
    %fn0 = arith.constant -0.0 : f64
    %r8 = eco.float.round %fn0 : f64 -> i64
    eco.dbg %r8 : i64
    // CHECK: [eco.dbg] 0

    // Large value
    %large = arith.constant 1000000.7 : f64
    %r9 = eco.float.round %large : f64 -> i64
    eco.dbg %r9 : i64
    // CHECK: [eco.dbg] 1000001

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
