// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test all 4 sign combinations for floored modulo (eco.int.modby).
// Elm uses floored division semantics where result has same sign as modulus.

module {
  func.func @main() -> i64 {
    // Case 1: positive % positive -> positive
    // 7 modBy 3 = 1 (7 = 2*3 + 1)
    %c7 = arith.constant 7 : i64
    %c3 = arith.constant 3 : i64
    %r1 = eco.int.modby %c3, %c7 : i64
    eco.dbg %r1 : i64
    // CHECK: [eco.dbg] 1

    // Case 2: negative % positive -> positive
    // -7 modBy 3 = 2 (floored: -7 = -3*3 + 2)
    %cn7 = arith.constant -7 : i64
    %r2 = eco.int.modby %c3, %cn7 : i64
    eco.dbg %r2 : i64
    // CHECK: [eco.dbg] 2

    // Case 3: positive % negative -> negative
    // 7 modBy -3 = -2 (floored: 7 = -2*(-3) + (-2))
    %cn3 = arith.constant -3 : i64
    %r3 = eco.int.modby %cn3, %c7 : i64
    eco.dbg %r3 : i64
    // CHECK: [eco.dbg] -2

    // Case 4: negative % negative -> negative
    // -7 modBy -3 = -1 (floored: -7 = 3*(-3) + (-1))
    %r4 = eco.int.modby %cn3, %cn7 : i64
    eco.dbg %r4 : i64
    // CHECK: [eco.dbg] -1

    // Edge case: x modBy 0 = 0
    %c0 = arith.constant 0 : i64
    %r5 = eco.int.modby %c0, %c7 : i64
    eco.dbg %r5 : i64
    // CHECK: [eco.dbg] 0

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
