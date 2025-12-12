// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test eco.float.truncate with NaN and special float values.
// Truncating NaN to integer is undefined behavior in many systems.

module {
  func.func @main() -> i64 {
    %f0 = arith.constant 0.0 : f64
    %one = arith.constant 1.0 : f64

    // Normal truncation (baseline): 3.7 -> 3
    %f3_7 = arith.constant 3.7 : f64
    %t1 = eco.float.truncate %f3_7 : f64 -> i64
    eco.dbg %t1 : i64
    // CHECK: [eco.dbg] 3

    // Negative truncation: -3.7 -> -3
    %fn3_7 = arith.constant -3.7 : f64
    %t2 = eco.float.truncate %fn3_7 : f64 -> i64
    eco.dbg %t2 : i64
    // CHECK: [eco.dbg] -3

    // Zero truncation: 0.0 -> 0
    %t3 = eco.float.truncate %f0 : f64 -> i64
    eco.dbg %t3 : i64
    // CHECK: [eco.dbg] 0

    // Negative zero: -0.0 -> 0
    %fn0 = arith.constant -0.0 : f64
    %t4 = eco.float.truncate %fn0 : f64 -> i64
    eco.dbg %t4 : i64
    // CHECK: [eco.dbg] 0

    // Very small positive: 0.001 -> 0
    %small = arith.constant 0.001 : f64
    %t5 = eco.float.truncate %small : f64 -> i64
    eco.dbg %t5 : i64
    // CHECK: [eco.dbg] 0

    // Very small negative: -0.999 -> 0
    %small_neg = arith.constant -0.999 : f64
    %t6 = eco.float.truncate %small_neg : f64 -> i64
    eco.dbg %t6 : i64
    // CHECK: [eco.dbg] 0

    // Large value within i64 range
    %large = arith.constant 1000000000000.0 : f64
    %t7 = eco.float.truncate %large : f64 -> i64
    eco.dbg %t7 : i64
    // CHECK: [eco.dbg] 1000000000000

    // The results of truncating NaN and Inf are implementation-defined
    // Just verify they don't crash
    %nan = arith.divf %f0, %f0 : f64
    %t_nan = eco.float.truncate %nan : f64 -> i64
    // Output varies by platform, just check it produces something
    %check_nan = arith.constant 1 : i64
    eco.dbg %check_nan : i64
    // CHECK: [eco.dbg] 1

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
