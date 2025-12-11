// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test shift operations with various shift amounts.
// Focus on well-defined behavior (shift by 0-63).

module {
  func.func @main() -> i64 {
    %val = arith.constant 1 : i64
    %neg_val = arith.constant -1 : i64

    // Shift left by 1: 1 << 1 = 2
    %c1 = arith.constant 1 : i64
    %shl_1 = eco.int.shl %c1, %val : i64
    eco.dbg %shl_1 : i64
    // CHECK: 2

    // Shift left by 10: 1 << 10 = 1024
    %c10 = arith.constant 10 : i64
    %shl_10 = eco.int.shl %c10, %val : i64
    eco.dbg %shl_10 : i64
    // CHECK: 1024

    // Shift left by 63: 1 << 63 = MIN_INT64
    %c63 = arith.constant 63 : i64
    %shl_63 = eco.int.shl %c63, %val : i64
    eco.dbg %shl_63 : i64
    // CHECK: -9223372036854775808

    // Shift left by 0: 1 << 0 = 1
    %c0 = arith.constant 0 : i64
    %shl_0 = eco.int.shl %c0, %val : i64
    eco.dbg %shl_0 : i64
    // CHECK: 1

    // Arithmetic right shift: -1 >> 1 = -1 (sign extension)
    %shr_neg = eco.int.shr %c1, %neg_val : i64
    eco.dbg %shr_neg : i64
    // CHECK: -1

    // Arithmetic right shift: -1 >> 63 = -1
    %shr_neg_63 = eco.int.shr %c63, %neg_val : i64
    eco.dbg %shr_neg_63 : i64
    // CHECK: -1

    // Logical right shift: -1 >>> 1
    %shru_1 = eco.int.shru %c1, %neg_val : i64
    eco.dbg %shru_1 : i64
    // -1 is all 1s, >>> 1 gives max positive / 2
    // CHECK: 9223372036854775807

    // Logical right shift: -1 >>> 63 = 1
    %shru_63 = eco.int.shru %c63, %neg_val : i64
    eco.dbg %shru_63 : i64
    // CHECK: 1

    // Shift positive value right: 1024 >> 10 = 1
    %c1024 = arith.constant 1024 : i64
    %shr_1024 = eco.int.shr %c10, %c1024 : i64
    eco.dbg %shr_1024 : i64
    // CHECK: 1

    // Shift left then right should recover original (for small amounts)
    %shifted = eco.int.shl %c10, %val : i64
    %recovered = eco.int.shr %c10, %shifted : i64
    eco.dbg %recovered : i64
    // CHECK: 1

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
