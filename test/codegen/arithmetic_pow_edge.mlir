// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test integer power edge cases.

module {
  func.func @main() -> i64 {
    %c0 = arith.constant 0 : i64
    %c1 = arith.constant 1 : i64
    %c2 = arith.constant 2 : i64
    %c3 = arith.constant 3 : i64
    %c10 = arith.constant 10 : i64
    %c62 = arith.constant 62 : i64
    %c63 = arith.constant 63 : i64
    %large = arith.constant 1000000 : i64

    // 0^0 = 1 (mathematical convention)
    %pow_0_0 = eco.int.pow %c0, %c0 : i64
    eco.dbg %pow_0_0 : i64
    // CHECK: 1

    // x^0 = 1 for any x
    %pow_10_0 = eco.int.pow %c10, %c0 : i64
    eco.dbg %pow_10_0 : i64
    // CHECK: 1

    // 0^n = 0 for n > 0
    %pow_0_10 = eco.int.pow %c0, %c10 : i64
    eco.dbg %pow_0_10 : i64
    // CHECK: 0

    // 1^n = 1 for any n
    %pow_1_large = eco.int.pow %c1, %large : i64
    eco.dbg %pow_1_large : i64
    // CHECK: 1

    // (-1)^2 = 1
    %neg1 = arith.constant -1 : i64
    %pow_neg1_2 = eco.int.pow %neg1, %c2 : i64
    eco.dbg %pow_neg1_2 : i64
    // CHECK: 1

    // (-1)^3 = -1
    %pow_neg1_3 = eco.int.pow %neg1, %c3 : i64
    eco.dbg %pow_neg1_3 : i64
    // CHECK: -1

    // 2^62 = 4611686018427387904 (within i64 range)
    %pow_2_62 = eco.int.pow %c2, %c62 : i64
    eco.dbg %pow_2_62 : i64
    // CHECK: 4611686018427387904

    // 2^63 overflows (MAX_INT + 1)
    %pow_2_63 = eco.int.pow %c2, %c63 : i64
    eco.dbg %pow_2_63 : i64
    // CHECK: -9223372036854775808

    // 3^3 = 27
    %pow_3_3 = eco.int.pow %c3, %c3 : i64
    eco.dbg %pow_3_3 : i64
    // CHECK: 27

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
