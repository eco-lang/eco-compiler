// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test remainderBy edge cases (truncated division remainder).
// remainderBy n x = x - n * truncate(x / n)
// Result has the same sign as x (dividend).

module {
  func.func @main() -> i64 {
    // remainderBy (-5) 17 = 17 - (-5) * truncate(17 / -5)
    //                     = 17 - (-5) * truncate(-3.4)
    //                     = 17 - (-5) * (-3)
    //                     = 17 - 15 = 2
    %neg5 = arith.constant -5 : i64
    %i17 = arith.constant 17 : i64
    %rem1 = eco.int.remainderby %neg5, %i17 : i64
    eco.dbg %rem1 : i64
    // CHECK: 2

    // remainderBy (-5) (-17) = -17 - (-5) * truncate(-17 / -5)
    //                        = -17 - (-5) * truncate(3.4)
    //                        = -17 - (-5) * 3
    //                        = -17 + 15 = -2
    %neg17 = arith.constant -17 : i64
    %rem2 = eco.int.remainderby %neg5, %neg17 : i64
    eco.dbg %rem2 : i64
    // CHECK: -2

    // remainderBy 5 (-17) = -17 - 5 * truncate(-17 / 5)
    //                     = -17 - 5 * truncate(-3.4)
    //                     = -17 - 5 * (-3)
    //                     = -17 + 15 = -2
    %i5 = arith.constant 5 : i64
    %rem3 = eco.int.remainderby %i5, %neg17 : i64
    eco.dbg %rem3 : i64
    // CHECK: -2

    // remainderBy 5 17 = 17 - 5 * truncate(17 / 5)
    //                  = 17 - 5 * 3
    //                  = 17 - 15 = 2
    %rem4 = eco.int.remainderby %i5, %i17 : i64
    eco.dbg %rem4 : i64
    // CHECK: 2

    // remainderBy with 0 divisor returns 0
    %i0 = arith.constant 0 : i64
    %rem5 = eco.int.remainderby %i0, %i17 : i64
    eco.dbg %rem5 : i64
    // CHECK: 0

    // remainderBy (-1) x = 0
    %neg1 = arith.constant -1 : i64
    %rem6 = eco.int.remainderby %neg1, %i17 : i64
    eco.dbg %rem6 : i64
    // CHECK: 0

    // remainderBy with MIN_INT and -1
    // This could overflow in C, test behavior
    %min_int = arith.constant -9223372036854775808 : i64
    %rem7 = eco.int.remainderby %neg1, %min_int : i64
    eco.dbg %rem7 : i64
    // CHECK: 0

    // Verify difference between modBy and remainderBy:
    // modBy 4 (-7) = 1 (floored)
    // remainderBy 4 (-7) = -3 (truncated)
    %i4 = arith.constant 4 : i64
    %neg7 = arith.constant -7 : i64
    %modby_result = eco.int.modby %i4, %neg7 : i64
    eco.dbg %modby_result : i64
    // CHECK: 1
    %remby_result = eco.int.remainderby %i4, %neg7 : i64
    eco.dbg %remby_result : i64
    // CHECK: -3

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
