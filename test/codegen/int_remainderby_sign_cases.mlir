// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test all 4 sign combinations for truncated remainder (eco.int.remainderby).
// Result has same sign as dividend (x).

module {
  func.func @main() -> i64 {
    // Case 1: positive % positive -> positive
    // 7 remainderBy 3 = 1
    %c7 = arith.constant 7 : i64
    %c3 = arith.constant 3 : i64
    %r1 = eco.int.remainderby %c3, %c7 : i64
    eco.dbg %r1 : i64
    // CHECK: [eco.dbg] 1

    // Case 2: negative % positive -> negative
    // -7 remainderBy 3 = -1 (truncated: -7 = -2*3 + (-1))
    %cn7 = arith.constant -7 : i64
    %r2 = eco.int.remainderby %c3, %cn7 : i64
    eco.dbg %r2 : i64
    // CHECK: [eco.dbg] -1

    // Case 3: positive % negative -> positive
    // 7 remainderBy -3 = 1 (truncated: 7 = -2*(-3) + 1)
    %cn3 = arith.constant -3 : i64
    %r3 = eco.int.remainderby %cn3, %c7 : i64
    eco.dbg %r3 : i64
    // CHECK: [eco.dbg] 1

    // Case 4: negative % negative -> negative
    // -7 remainderBy -3 = -1 (truncated: -7 = 2*(-3) + (-1))
    %r4 = eco.int.remainderby %cn3, %cn7 : i64
    eco.dbg %r4 : i64
    // CHECK: [eco.dbg] -1

    // Edge case: x remainderBy 0 = 0
    %c0 = arith.constant 0 : i64
    %r5 = eco.int.remainderby %c0, %c7 : i64
    eco.dbg %r5 : i64
    // CHECK: [eco.dbg] 0

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
