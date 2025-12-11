// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test shift operations with shift amounts larger than 64.
// Behavior is typically defined modulo 64 or undefined.

module {
  func.func @main() -> i64 {
    %val = arith.constant 1 : i64
    %c65 = arith.constant 65 : i64
    %c100 = arith.constant 100 : i64
    %c128 = arith.constant 128 : i64

    // Shift by 65 (65 mod 64 = 1 in some implementations)
    %shl65 = eco.int.shl %c65, %val : i64
    eco.dbg %shl65 : i64
    // Undefined behavior - output varies

    // Shift by 100 (100 mod 64 = 36)
    %shl100 = eco.int.shl %c100, %val : i64
    eco.dbg %shl100 : i64
    // Undefined behavior - output varies

    // Shift by 128 (128 mod 64 = 0)
    %shl128 = eco.int.shl %c128, %val : i64
    eco.dbg %shl128 : i64
    // Undefined behavior - output varies

    // Right shifts with large amounts
    %neg1 = arith.constant -1 : i64
    %shr65 = eco.int.shr %c65, %neg1 : i64
    eco.dbg %shr65 : i64
    // Undefined behavior - output varies

    %shru65 = eco.int.shru %c65, %neg1 : i64
    eco.dbg %shru65 : i64
    // Undefined behavior - output varies

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
