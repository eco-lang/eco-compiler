// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test modBy with negative modulus (Elm's floored modulo semantics).
// modBy n x = x - n * floor(x / n)
// Result always has the same sign as n.

module {
  func.func @main() -> i64 {
    // modBy (-5) 17 = 17 - (-5) * floor(17 / -5)
    //              = 17 - (-5) * floor(-3.4)
    //              = 17 - (-5) * (-4)
    //              = 17 - 20 = -3
    %neg5 = arith.constant -5 : i64
    %i17 = arith.constant 17 : i64
    %mod1 = eco.int.modby %neg5, %i17 : i64
    eco.dbg %mod1 : i64
    // CHECK: -3

    // modBy (-5) (-17) = -17 - (-5) * floor(-17 / -5)
    //                  = -17 - (-5) * floor(3.4)
    //                  = -17 - (-5) * 3
    //                  = -17 + 15 = -2
    %neg17 = arith.constant -17 : i64
    %mod2 = eco.int.modby %neg5, %neg17 : i64
    eco.dbg %mod2 : i64
    // CHECK: -2

    // modBy (-3) 10 = 10 - (-3) * floor(10 / -3)
    //              = 10 - (-3) * floor(-3.33)
    //              = 10 - (-3) * (-4)
    //              = 10 - 12 = -2
    %neg3 = arith.constant -3 : i64
    %i10 = arith.constant 10 : i64
    %mod3 = eco.int.modby %neg3, %i10 : i64
    eco.dbg %mod3 : i64
    // CHECK: -2

    // modBy (-3) (-10) = -10 - (-3) * floor(-10 / -3)
    //                  = -10 - (-3) * floor(3.33)
    //                  = -10 - (-3) * 3
    //                  = -10 + 9 = -1
    %neg10 = arith.constant -10 : i64
    %mod4 = eco.int.modby %neg3, %neg10 : i64
    eco.dbg %mod4 : i64
    // CHECK: -1

    // modBy (-1) x always = 0 (any integer is divisible by -1)
    %neg1 = arith.constant -1 : i64
    %mod5 = eco.int.modby %neg1, %i17 : i64
    eco.dbg %mod5 : i64
    // CHECK: 0

    %mod6 = eco.int.modby %neg1, %neg17 : i64
    eco.dbg %mod6 : i64
    // CHECK: 0

    // modBy 5 (-17) = -17 - 5 * floor(-17 / 5)
    //              = -17 - 5 * floor(-3.4)
    //              = -17 - 5 * (-4)
    //              = -17 + 20 = 3
    %i5 = arith.constant 5 : i64
    %mod7 = eco.int.modby %i5, %neg17 : i64
    eco.dbg %mod7 : i64
    // CHECK: 3

    // Confirm: modBy 0 returns 0 (per Elm semantics)
    %i0 = arith.constant 0 : i64
    %mod8 = eco.int.modby %i0, %i17 : i64
    eco.dbg %mod8 : i64
    // CHECK: 0

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
