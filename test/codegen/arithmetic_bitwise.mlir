// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test bitwise operations.

module {
  func.func @main() -> i64 {
    %i5 = arith.constant 5 : i64     // 0101
    %i3 = arith.constant 3 : i64     // 0011
    %i2 = arith.constant 2 : i64
    %i1 = arith.constant 1 : i64
    %neg1 = arith.constant -1 : i64  // all 1s
    %i8 = arith.constant 8 : i64     // 1000

    // eco.int.and: 5 & 3 = 1  (0101 & 0011 = 0001)
    %and = eco.int.and %i5, %i3 : i64
    eco.dbg %and : i64
    // CHECK: 1

    // eco.int.or: 5 | 3 = 7  (0101 | 0011 = 0111)
    %or = eco.int.or %i5, %i3 : i64
    eco.dbg %or : i64
    // CHECK: 7

    // eco.int.xor: 5 ^ 3 = 6  (0101 ^ 0011 = 0110)
    %xor = eco.int.xor %i5, %i3 : i64
    eco.dbg %xor : i64
    // CHECK: 6

    // eco.int.complement: complement 0 = -1 (all bits set)
    %i0 = arith.constant 0 : i64
    %comp = eco.int.complement %i0 : i64
    eco.dbg %comp : i64
    // CHECK: -1

    // eco.int.shl: shiftLeftBy 2 1 = 4  (1 << 2 = 4)
    %shl = eco.int.shl %i2, %i1 : i64
    eco.dbg %shl : i64
    // CHECK: 4

    // eco.int.shr: shiftRightBy 2 8 = 2  (8 >> 2 = 2, arithmetic)
    %shr = eco.int.shr %i2, %i8 : i64
    eco.dbg %shr : i64
    // CHECK: 2

    // eco.int.shr with negative: shiftRightBy 2 (-8) = -2 (preserves sign)
    %neg8 = arith.constant -8 : i64
    %shr_neg = eco.int.shr %i2, %neg8 : i64
    eco.dbg %shr_neg : i64
    // CHECK: -2

    // eco.int.shru: shiftRightZfBy 2 8 = 2 (logical, zero-fill)
    %shru = eco.int.shru %i2, %i8 : i64
    eco.dbg %shru : i64
    // CHECK: 2

    // eco.int.shru with negative gives large positive
    // -8 logical right shift 2 = 4611686018427387902 on 64-bit
    %shru_neg = eco.int.shru %i2, %neg8 : i64
    // Just check it's positive (very large number)
    %is_pos = eco.int.gt %shru_neg, %i0 : i64
    %boxed = eco.box %is_pos : i1 -> !eco.value
    eco.dbg %boxed : !eco.value
    // CHECK: True

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
