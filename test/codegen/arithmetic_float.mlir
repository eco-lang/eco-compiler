// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test float arithmetic operations.

module {
  func.func @main() -> i64 {
    %f10 = arith.constant 10.0 : f64
    %f3 = arith.constant 3.0 : f64
    %f2 = arith.constant 2.0 : f64
    %f4 = arith.constant 4.0 : f64
    %f0_5 = arith.constant 0.5 : f64
    %neg3 = arith.constant -3.0 : f64
    %f1_5 = arith.constant 1.5 : f64
    %f2_7 = arith.constant 2.7 : f64
    %neg2_7 = arith.constant -2.7 : f64

    // eco.float.add: 10.0 + 3.0 = 13.0
    %add = eco.float.add %f10, %f3 : f64
    eco.dbg %add : f64
    // CHECK: 13

    // eco.float.sub: 10.0 - 3.0 = 7.0
    %sub = eco.float.sub %f10, %f3 : f64
    eco.dbg %sub : f64
    // CHECK: 7

    // eco.float.mul: 10.0 * 3.0 = 30.0
    %mul = eco.float.mul %f10, %f3 : f64
    eco.dbg %mul : f64
    // CHECK: 30

    // eco.float.div: 10.0 / 4.0 = 2.5
    %div = eco.float.div %f10, %f4 : f64
    eco.dbg %div : f64
    // CHECK: 2.5

    // eco.float.negate: negate 3.0 = -3.0
    %neg = eco.float.negate %f3 : f64
    eco.dbg %neg : f64
    // CHECK: -3

    // eco.float.abs: abs (-3.0) = 3.0
    %abs = eco.float.abs %neg3 : f64
    eco.dbg %abs : f64
    // CHECK: 3

    // eco.float.pow: 2.0 ^ 10.0 = 1024.0
    %pow = eco.float.pow %f2, %f10 : f64
    eco.dbg %pow : f64
    // CHECK: 1024

    // eco.float.sqrt: sqrt(4.0) = 2.0
    %sqrt = eco.float.sqrt %f4 : f64
    eco.dbg %sqrt : f64
    // CHECK: 2

    // eco.int.toFloat: toFloat 3 = 3.0
    %i3 = arith.constant 3 : i64
    %toFloat = eco.int.toFloat %i3 : i64 -> f64
    eco.dbg %toFloat : f64
    // CHECK: 3

    // eco.float.round: round 2.7 = 3
    %round1 = eco.float.round %f2_7 : f64 -> i64
    eco.dbg %round1 : i64
    // CHECK: 3

    // eco.float.round: round (-2.7) = -3
    %round2 = eco.float.round %neg2_7 : f64 -> i64
    eco.dbg %round2 : i64
    // CHECK: -3

    // eco.float.floor: floor 2.7 = 2
    %floor1 = eco.float.floor %f2_7 : f64 -> i64
    eco.dbg %floor1 : i64
    // CHECK: 2

    // eco.float.floor: floor (-2.7) = -3
    %floor2 = eco.float.floor %neg2_7 : f64 -> i64
    eco.dbg %floor2 : i64
    // CHECK: -3

    // eco.float.ceiling: ceiling 2.7 = 3
    %ceil1 = eco.float.ceiling %f2_7 : f64 -> i64
    eco.dbg %ceil1 : i64
    // CHECK: 3

    // eco.float.ceiling: ceiling (-2.7) = -2
    %ceil2 = eco.float.ceiling %neg2_7 : f64 -> i64
    eco.dbg %ceil2 : i64
    // CHECK: -2

    // eco.float.truncate: truncate 2.7 = 2
    %trunc1 = eco.float.truncate %f2_7 : f64 -> i64
    eco.dbg %trunc1 : i64
    // CHECK: 2

    // eco.float.truncate: truncate (-2.7) = -2
    %trunc2 = eco.float.truncate %neg2_7 : f64 -> i64
    eco.dbg %trunc2 : i64
    // CHECK: -2

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
