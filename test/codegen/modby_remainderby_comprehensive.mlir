// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Comprehensive modBy vs remainderBy test across all sign combinations.
// modBy uses floored division (result has same sign as divisor).
// remainderBy uses truncated division (result has same sign as dividend).

module {
  func.func @main() -> i64 {
    %p7 = arith.constant 7 : i64    // positive
    %n7 = arith.constant -7 : i64   // negative
    %p3 = arith.constant 3 : i64    // positive divisor
    %n3 = arith.constant -3 : i64   // negative divisor
    %zero = arith.constant 0 : i64

    // ===== modBy (floored) =====
    // Result has same sign as divisor (second argument to modBy)

    // modBy 3 7 = 1 (7 = 2*3 + 1)
    %mod_pp = eco.int.modby %p3, %p7 : i64
    eco.dbg %mod_pp : i64
    // CHECK: 1

    // modBy 3 (-7) = 2 (floored: -7 = -3*3 + 2)
    %mod_pn = eco.int.modby %p3, %n7 : i64
    eco.dbg %mod_pn : i64
    // CHECK: 2

    // modBy (-3) 7 = -2 (floored: 7 = -2*(-3) + (-2) = 6 + (-2) = 4? No...)
    // Actually: 7 = -3 * (-3) + (-2) = 9 - 2 = 7. Wait...
    // floored div: floor(7 / -3) = floor(-2.33) = -3
    // 7 = -3 * (-3) + r => 7 = 9 + r => r = -2
    %mod_np = eco.int.modby %n3, %p7 : i64
    eco.dbg %mod_np : i64
    // CHECK: -2

    // modBy (-3) (-7) = -1 (floored: floor(-7/-3) = floor(2.33) = 2)
    // -7 = 2 * (-3) + r => -7 = -6 + r => r = -1
    %mod_nn = eco.int.modby %n3, %n7 : i64
    eco.dbg %mod_nn : i64
    // CHECK: -1

    // modBy 3 0 = 0
    %mod_z = eco.int.modby %p3, %zero : i64
    eco.dbg %mod_z : i64
    // CHECK: 0

    // modBy 0 7 = 0 (special case: div by zero returns 0)
    %mod_dz = eco.int.modby %zero, %p7 : i64
    eco.dbg %mod_dz : i64
    // CHECK: 0

    // ===== remainderBy (truncated) =====
    // Result has same sign as dividend (second argument to remainderBy)

    // remainderBy 3 7 = 1
    %rem_pp = eco.int.remainderby %p3, %p7 : i64
    eco.dbg %rem_pp : i64
    // CHECK: 1

    // remainderBy 3 (-7) = -1 (truncated: -7 / 3 = -2, -7 = -2*3 + (-1))
    %rem_pn = eco.int.remainderby %p3, %n7 : i64
    eco.dbg %rem_pn : i64
    // CHECK: -1

    // remainderBy (-3) 7 = 1 (truncated: 7 / -3 = -2, 7 = -2*(-3) + 1)
    %rem_np = eco.int.remainderby %n3, %p7 : i64
    eco.dbg %rem_np : i64
    // CHECK: 1

    // remainderBy (-3) (-7) = -1 (truncated: -7 / -3 = 2, -7 = 2*(-3) + (-1))
    %rem_nn = eco.int.remainderby %n3, %n7 : i64
    eco.dbg %rem_nn : i64
    // CHECK: -1

    // remainderBy 3 0 = 0
    %rem_z = eco.int.remainderby %p3, %zero : i64
    eco.dbg %rem_z : i64
    // CHECK: 0

    // remainderBy 0 7 = 0 (special case)
    %rem_dz = eco.int.remainderby %zero, %p7 : i64
    eco.dbg %rem_dz : i64
    // CHECK: 0

    // Additional test: larger numbers
    %p17 = arith.constant 17 : i64
    %p5 = arith.constant 5 : i64
    // modBy 5 17 = 2
    %mod_17_5 = eco.int.modby %p5, %p17 : i64
    eco.dbg %mod_17_5 : i64
    // CHECK: 2

    // modBy 5 (-17) = 3
    %n17 = arith.constant -17 : i64
    %mod_n17_5 = eco.int.modby %p5, %n17 : i64
    eco.dbg %mod_n17_5 : i64
    // CHECK: 3

    return %zero : i64
  }
}
