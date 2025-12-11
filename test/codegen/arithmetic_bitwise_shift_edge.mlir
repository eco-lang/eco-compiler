// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test bitwise shift edge cases.
// Note: Shift operations have syntax eco.int.shl %shift_amount, %value

module {
  func.func @main() -> i64 {
    %val = arith.constant 1 : i64
    %negval = arith.constant -8 : i64
    %c0 = arith.constant 0 : i64
    %c1 = arith.constant 1 : i64
    %c2 = arith.constant 2 : i64
    %c63 = arith.constant 63 : i64
    %c31 = arith.constant 31 : i64

    // Shift left by 0 = identity: 1 << 0 = 1
    %shl_0 = eco.int.shl %c0, %val : i64
    eco.dbg %shl_0 : i64
    // CHECK: 1

    // Shift right by 0 = identity: 1 >> 0 = 1
    %shr_0 = eco.int.shr %c0, %val : i64
    eco.dbg %shr_0 : i64
    // CHECK: 1

    // Shift unsigned right by 0 = identity
    %shru_0 = eco.int.shru %c0, %val : i64
    eco.dbg %shru_0 : i64
    // CHECK: 1

    // Shift left by 1: 1 << 1 = 2
    %shl_1 = eco.int.shl %c1, %val : i64
    eco.dbg %shl_1 : i64
    // CHECK: 2

    // Shift left by 63 (max without overflow for value 1): 1 << 63
    %shl_63 = eco.int.shl %c63, %val : i64
    eco.dbg %shl_63 : i64
    // CHECK: -9223372036854775808

    // Shift right by 63 (for MAX_INT): MAX >> 63 = 0
    %max_int = arith.constant 9223372036854775807 : i64
    %shr_63 = eco.int.shr %c63, %max_int : i64
    eco.dbg %shr_63 : i64
    // CHECK: 0

    // Arithmetic shift right by 63 for -1: -1 >> 63 = -1 (sign extends)
    %neg1 = arith.constant -1 : i64
    %shr_neg_63 = eco.int.shr %c63, %neg1 : i64
    eco.dbg %shr_neg_63 : i64
    // CHECK: -1

    // Logical shift right by 63 for -1: -1 >>> 63 = 1
    %shru_neg_63 = eco.int.shru %c63, %neg1 : i64
    eco.dbg %shru_neg_63 : i64
    // CHECK: 1

    // Shift right negative value by 1 (arithmetic): -8 >> 1 = -4
    %shr_neg = eco.int.shr %c1, %negval : i64
    eco.dbg %shr_neg : i64
    // CHECK: -4

    // Shift right unsigned negative value by 1: -8 >>> 1 = large positive
    %shru_neg = eco.int.shru %c1, %negval : i64
    eco.dbg %shru_neg : i64
    // CHECK: 9223372036854775804

    // Multiple bit shift: 16 >> 2 = 4
    %val16 = arith.constant 16 : i64
    %shr_16 = eco.int.shr %c2, %val16 : i64
    eco.dbg %shr_16 : i64
    // CHECK: 4

    // Shift 0 left by 31: 0 << 31 = 0
    %shl_zero = eco.int.shl %c31, %c0 : i64
    eco.dbg %shl_zero : i64
    // CHECK: 0

    // Shift 0 right by 31: 0 >> 31 = 0
    %shr_zero = eco.int.shr %c31, %c0 : i64
    eco.dbg %shr_zero : i64
    // CHECK: 0

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
