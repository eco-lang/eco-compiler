// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test integer arithmetic operations with Elm semantics.

module {
  func.func @main() -> i64 {
    // Basic arithmetic
    %i10 = arith.constant 10 : i64
    %i3 = arith.constant 3 : i64
    %i2 = arith.constant 2 : i64
    %i0 = arith.constant 0 : i64
    %neg7 = arith.constant -7 : i64
    %i4 = arith.constant 4 : i64
    %neg4 = arith.constant -4 : i64
    %i7 = arith.constant 7 : i64

    // eco.int.add: 10 + 3 = 13
    %add = eco.int.add %i10, %i3 : i64
    eco.dbg %add : i64
    // CHECK: 13

    // eco.int.sub: 10 - 3 = 7
    %sub = eco.int.sub %i10, %i3 : i64
    eco.dbg %sub : i64
    // CHECK: 7

    // eco.int.mul: 10 * 3 = 30
    %mul = eco.int.mul %i10, %i3 : i64
    eco.dbg %mul : i64
    // CHECK: 30

    // eco.int.div: 10 // 3 = 3
    %div = eco.int.div %i10, %i3 : i64
    eco.dbg %div : i64
    // CHECK: 3

    // eco.int.div by zero returns 0 (Elm semantics)
    %divzero = eco.int.div %i10, %i0 : i64
    eco.dbg %divzero : i64
    // CHECK: 0

    // eco.int.modby: modBy 4 7 = 3
    %mod1 = eco.int.modby %i4, %i7 : i64
    eco.dbg %mod1 : i64
    // CHECK: 3

    // eco.int.modby: modBy 4 (-7) = 1 (floored, not -3)
    %mod2 = eco.int.modby %i4, %neg7 : i64
    eco.dbg %mod2 : i64
    // CHECK: 1

    // eco.int.modby with 0 returns 0
    %modzero = eco.int.modby %i0, %i7 : i64
    eco.dbg %modzero : i64
    // CHECK: 0

    // eco.int.remainderby: remainderBy 4 (-7) = -3 (truncated)
    %rem = eco.int.remainderby %i4, %neg7 : i64
    eco.dbg %rem : i64
    // CHECK: -3

    // eco.int.negate: negate 7 = -7
    %neg = eco.int.negate %i7 : i64
    eco.dbg %neg : i64
    // CHECK: -7

    // eco.int.abs: abs (-7) = 7
    %abs = eco.int.abs %neg7 : i64
    eco.dbg %abs : i64
    // CHECK: 7

    // eco.int.pow: 2 ^ 10 = 1024
    %pow = eco.int.pow %i2, %i10 : i64
    eco.dbg %pow : i64
    // CHECK: 1024

    // eco.int.pow with negative exponent returns 0
    %powneg = eco.int.pow %i2, %neg7 : i64
    eco.dbg %powneg : i64
    // CHECK: 0

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
