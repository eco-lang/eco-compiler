// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test eco.float.round at half values (ties away from zero).
// Elm's round uses "half away from zero" rounding.

module {
  func.func @main() -> i64 {
    // Positive half values
    %f0_5 = arith.constant 0.5 : f64
    %r0_5 = eco.float.round %f0_5 : f64 -> i64
    eco.dbg %r0_5 : i64
    // CHECK: 1

    %f1_5 = arith.constant 1.5 : f64
    %r1_5 = eco.float.round %f1_5 : f64 -> i64
    eco.dbg %r1_5 : i64
    // CHECK: 2

    %f2_5 = arith.constant 2.5 : f64
    %r2_5 = eco.float.round %f2_5 : f64 -> i64
    eco.dbg %r2_5 : i64
    // CHECK: 3

    %f3_5 = arith.constant 3.5 : f64
    %r3_5 = eco.float.round %f3_5 : f64 -> i64
    eco.dbg %r3_5 : i64
    // CHECK: 4

    // Negative half values (away from zero = more negative)
    %fn0_5 = arith.constant -0.5 : f64
    %rn0_5 = eco.float.round %fn0_5 : f64 -> i64
    eco.dbg %rn0_5 : i64
    // CHECK: -1

    %fn1_5 = arith.constant -1.5 : f64
    %rn1_5 = eco.float.round %fn1_5 : f64 -> i64
    eco.dbg %rn1_5 : i64
    // CHECK: -2

    %fn2_5 = arith.constant -2.5 : f64
    %rn2_5 = eco.float.round %fn2_5 : f64 -> i64
    eco.dbg %rn2_5 : i64
    // CHECK: -3

    // Non-half values (should round normally)
    %f1_4 = arith.constant 1.4 : f64
    %r1_4 = eco.float.round %f1_4 : f64 -> i64
    eco.dbg %r1_4 : i64
    // CHECK: 1

    %f1_6 = arith.constant 1.6 : f64
    %r1_6 = eco.float.round %f1_6 : f64 -> i64
    eco.dbg %r1_6 : i64
    // CHECK: 2

    %fn1_4 = arith.constant -1.4 : f64
    %rn1_4 = eco.float.round %fn1_4 : f64 -> i64
    eco.dbg %rn1_4 : i64
    // CHECK: -1

    %fn1_6 = arith.constant -1.6 : f64
    %rn1_6 = eco.float.round %fn1_6 : f64 -> i64
    eco.dbg %rn1_6 : i64
    // CHECK: -2

    // Edge: 0.0
    %f0 = arith.constant 0.0 : f64
    %r0 = eco.float.round %f0 : f64 -> i64
    eco.dbg %r0 : i64
    // CHECK: 0

    // Large half value
    %f100_5 = arith.constant 100.5 : f64
    %r100_5 = eco.float.round %f100_5 : f64 -> i64
    eco.dbg %r100_5 : i64
    // CHECK: 101

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
