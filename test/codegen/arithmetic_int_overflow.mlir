// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test integer overflow/wrapping behavior.
// Elm uses 64-bit signed integers that wrap on overflow.

module {
  func.func @main() -> i64 {
    // MAX_INT = 9223372036854775807 (2^63 - 1)
    // MIN_INT = -9223372036854775808 (-2^63)
    %max_int = arith.constant 9223372036854775807 : i64
    %min_int = arith.constant -9223372036854775808 : i64
    %c1 = arith.constant 1 : i64
    %c2 = arith.constant 2 : i64
    %neg1 = arith.constant -1 : i64

    // MAX_INT + 1 wraps to MIN_INT
    %overflow_add = eco.int.add %max_int, %c1 : i64
    eco.dbg %overflow_add : i64
    // CHECK: -9223372036854775808

    // MIN_INT - 1 wraps to MAX_INT
    %overflow_sub = eco.int.sub %min_int, %c1 : i64
    eco.dbg %overflow_sub : i64
    // CHECK: 9223372036854775807

    // MAX_INT * 2 wraps
    %overflow_mul = eco.int.mul %max_int, %c2 : i64
    eco.dbg %overflow_mul : i64
    // CHECK: -2

    // Large positive * large positive wraps
    %large = arith.constant 4611686018427387904 : i64
    %large_mul = eco.int.mul %large, %c2 : i64
    eco.dbg %large_mul : i64
    // CHECK: -9223372036854775808

    // Test that MIN_INT + (-1) wraps correctly
    %min_plus_neg = eco.int.add %min_int, %neg1 : i64
    eco.dbg %min_plus_neg : i64
    // CHECK: 9223372036854775807

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
