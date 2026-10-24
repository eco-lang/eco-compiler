// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test shift operations with shift amounts larger than 64, and a negative
// amount. The shift count is taken modulo 64 (count & 63, CGEN_085), as
// JavaScript takes it modulo 32 for its 32-bit Bitwise; the kernel C++
// Bitwise path masks identically.

module {
  func.func @main() -> i64 {
    %val = arith.constant 1 : i64
    %c65 = arith.constant 65 : i64
    %c100 = arith.constant 100 : i64
    %c128 = arith.constant 128 : i64
    %cm1 = arith.constant -1 : i64

    // Shift by 65 = shift by 1
    %shl65 = eco.int.shl %c65, %val : i64
    eco.dbg %shl65 : i64
    // CHECK: [eco.dbg] 2{{$}}

    // Shift by 100 = shift by 36
    %shl100 = eco.int.shl %c100, %val : i64
    eco.dbg %shl100 : i64
    // CHECK-NEXT: [eco.dbg] 68719476736{{$}}

    // Shift by 128 = shift by 0
    %shl128 = eco.int.shl %c128, %val : i64
    eco.dbg %shl128 : i64
    // CHECK-NEXT: [eco.dbg] 1{{$}}

    // Right shifts with large amounts
    %neg1 = arith.constant -1 : i64
    %shr65 = eco.int.shr %c65, %neg1 : i64
    eco.dbg %shr65 : i64
    // CHECK-NEXT: [eco.dbg] -1{{$}}

    // -1 >>> 65 = -1 >>> 1 = MAX_INT
    %shru65 = eco.int.shru %c65, %neg1 : i64
    eco.dbg %shru65 : i64
    // CHECK-NEXT: [eco.dbg] 9223372036854775807{{$}}

    // Negative amount: -1 & 63 = 63, so 1 << -1 = MIN_INT
    %shlm1 = eco.int.shl %cm1, %val : i64
    eco.dbg %shlm1 : i64
    // CHECK-NEXT: [eco.dbg] -9223372036854775808{{$}}

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
