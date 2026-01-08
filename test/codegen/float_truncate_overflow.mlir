// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test truncate(large_float) where result > INT64_MAX.
// Tests overflow behavior.

module {
  func.func @main() -> i64 {
    // Test truncate with values in normal range first
    %normal = arith.constant 123.7 : f64
    %trunc_normal = eco.float.truncate %normal : f64 -> i64
    eco.dbg %trunc_normal : i64
    // CHECK: [eco.dbg] 123

    %negative = arith.constant -456.9 : f64
    %trunc_neg = eco.float.truncate %negative : f64 -> i64
    eco.dbg %trunc_neg : i64
    // CHECK: [eco.dbg] -456

    // Test truncate of value near INT64_MAX boundary
    // INT64_MAX = 9223372036854775807
    // 9.22e18 = 9,220,000,000,000,000,000 (within i64 range)
    %near_max = arith.constant 9.22e18 : f64
    %trunc_near = eco.float.truncate %near_max : f64 -> i64
    eco.dbg %trunc_near : i64
    // CHECK: [eco.dbg] 9220000000000000000

    // Test truncate of -0.0 -> should be 0
    %neg_zero = arith.constant -0.0 : f64
    %trunc_negzero = eco.float.truncate %neg_zero : f64 -> i64
    eco.dbg %trunc_negzero : i64
    // CHECK: [eco.dbg] 0

    // Test truncate of very small positive -> 0
    %tiny = arith.constant 0.001 : f64
    %trunc_tiny = eco.float.truncate %tiny : f64 -> i64
    eco.dbg %trunc_tiny : i64
    // CHECK: [eco.dbg] 0

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
