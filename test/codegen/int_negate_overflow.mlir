// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test eco.int.negate including edge cases.
// Negating INT64_MIN wraps around (undefined behavior in C, but well-defined in LLVM).

module {
  func.func @main() -> i64 {
    // Normal negation
    %i42 = arith.constant 42 : i64
    %neg42 = eco.int.negate %i42 : i64
    eco.dbg %neg42 : i64
    // CHECK: -42

    // Negating negative
    %neg100 = arith.constant -100 : i64
    %pos100 = eco.int.negate %neg100 : i64
    eco.dbg %pos100 : i64
    // CHECK: 100

    // Negating zero
    %zero = arith.constant 0 : i64
    %neg_zero = eco.int.negate %zero : i64
    eco.dbg %neg_zero : i64
    // CHECK: 0

    // Negating 1
    %one = arith.constant 1 : i64
    %neg_one = eco.int.negate %one : i64
    eco.dbg %neg_one : i64
    // CHECK: -1

    // Negating -1
    %minus_one = arith.constant -1 : i64
    %pos_one = eco.int.negate %minus_one : i64
    eco.dbg %pos_one : i64
    // CHECK: 1

    // Large positive
    %large = arith.constant 9223372036854775000 : i64
    %neg_large = eco.int.negate %large : i64
    eco.dbg %neg_large : i64
    // CHECK: -9223372036854775000

    // INT64_MIN = -9223372036854775808
    // Negating it wraps to itself (overflow)
    %int_min = arith.constant -9223372036854775808 : i64
    %neg_min = eco.int.negate %int_min : i64
    // This wraps around to INT64_MIN due to two's complement
    eco.dbg %neg_min : i64
    // CHECK: -9223372036854775808

    return %zero : i64
  }
}
