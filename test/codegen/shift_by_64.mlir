// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test shift operations with shift amount of exactly 64 bits.
// This is a boundary condition - behavior may be undefined or platform-specific.

module {
  func.func @main() -> i64 {
    %val = arith.constant 1 : i64
    %c64 = arith.constant 64 : i64
    %c63 = arith.constant 63 : i64

    // Shift left by 63 (should work)
    %shl63 = eco.int.shl %c63, %val : i64
    eco.dbg %shl63 : i64
    // 1 << 63 = MIN_INT64 = -9223372036854775808
    // CHECK: -9223372036854775808

    // Shift left by 64 (undefined in C, but test what happens)
    %shl64 = eco.int.shl %c64, %val : i64
    eco.dbg %shl64 : i64
    // Undefined behavior - output varies

    // Shift right by 63 on -1 (all bits set)
    %neg1 = arith.constant -1 : i64
    %shr63 = eco.int.shr %c63, %neg1 : i64
    eco.dbg %shr63 : i64
    // Arithmetic shift right preserves sign: -1 >> 63 = -1
    // CHECK: -1

    // Shift right by 64
    %shr64 = eco.int.shr %c64, %neg1 : i64
    eco.dbg %shr64 : i64
    // Undefined behavior - output varies

    // Logical shift right by 63 on -1
    %shru63 = eco.int.shru %c63, %neg1 : i64
    eco.dbg %shru63 : i64
    // -1 (all 1s) >>> 63 = 1
    // CHECK: 1

    // Logical shift right by 64
    %shru64 = eco.int.shru %c64, %neg1 : i64
    eco.dbg %shru64 : i64
    // Undefined behavior - output varies

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
