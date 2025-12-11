// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Comprehensive test of modBy (floored modulo) with all sign combinations.
// Floored modulo: result has same sign as divisor (modulus).
// This tests the complex 9-operation logic in IntModByOpLowering.

module {
  func.func @main() -> i64 {
    // Test all 4 sign combinations: (+,+), (+,-), (-,+), (-,-)
    // modBy modulus x = floored remainder

    // Positive modulus, positive x
    %m3 = arith.constant 3 : i64
    %x7 = arith.constant 7 : i64
    %r1 = eco.int.modby %m3, %x7 : i64
    eco.dbg %r1 : i64
    // 7 mod 3 = 1
    // CHECK: 1

    // Positive modulus, negative x
    %xn7 = arith.constant -7 : i64
    %r2 = eco.int.modby %m3, %xn7 : i64
    eco.dbg %r2 : i64
    // -7 mod 3: truncated = -1, floored = 2 (adjust by adding 3)
    // CHECK: 2

    // Negative modulus, positive x
    %mn3 = arith.constant -3 : i64
    %r3 = eco.int.modby %mn3, %x7 : i64
    eco.dbg %r3 : i64
    // 7 mod -3: truncated = 1, floored = -2 (adjust by adding -3)
    // CHECK: -2

    // Negative modulus, negative x
    %r4 = eco.int.modby %mn3, %xn7 : i64
    eco.dbg %r4 : i64
    // -7 mod -3: truncated = -1, floored = -1 (same sign, no adjustment)
    // CHECK: -1

    // Edge case: x divisible by modulus
    %x9 = arith.constant 9 : i64
    %r5 = eco.int.modby %m3, %x9 : i64
    eco.dbg %r5 : i64
    // 9 mod 3 = 0
    // CHECK: 0

    // Edge case: negative x divisible by positive modulus
    %xn9 = arith.constant -9 : i64
    %r6 = eco.int.modby %m3, %xn9 : i64
    eco.dbg %r6 : i64
    // -9 mod 3 = 0 (no adjustment needed when remainder is 0)
    // CHECK: 0

    // Edge case: modulus = 0 (should return 0)
    %m0 = arith.constant 0 : i64
    %r7 = eco.int.modby %m0, %x7 : i64
    eco.dbg %r7 : i64
    // CHECK: 0

    // Large values
    %big = arith.constant 1000000007 : i64
    %x_large = arith.constant 123456789012345 : i64
    %r8 = eco.int.modby %big, %x_large : i64
    eco.dbg %r8 : i64
    // 123456789012345 mod 1000000007 = some value
    // CHECK: 788148153

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
