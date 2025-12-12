// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test rounding at half values (0.5, 1.5, 2.5, -0.5, -1.5).
// Elm uses "round half away from zero" semantics.

module {
  func.func @main() -> i64 {
    // 0.5 -> 1 (round away from zero)
    %half = arith.constant 0.5 : f64
    %r1 = eco.float.round %half : f64 -> i64
    eco.dbg %r1 : i64
    // CHECK: [eco.dbg] 1

    // 1.5 -> 2 (round away from zero)
    %one_half = arith.constant 1.5 : f64
    %r2 = eco.float.round %one_half : f64 -> i64
    eco.dbg %r2 : i64
    // CHECK: [eco.dbg] 2

    // 2.5 -> 3 (round away from zero)
    %two_half = arith.constant 2.5 : f64
    %r3 = eco.float.round %two_half : f64 -> i64
    eco.dbg %r3 : i64
    // CHECK: [eco.dbg] 3

    // -0.5 -> -1 (round away from zero)
    %neg_half = arith.constant -0.5 : f64
    %r4 = eco.float.round %neg_half : f64 -> i64
    eco.dbg %r4 : i64
    // CHECK: [eco.dbg] -1

    // -1.5 -> -2 (round away from zero)
    %neg_one_half = arith.constant -1.5 : f64
    %r5 = eco.float.round %neg_one_half : f64 -> i64
    eco.dbg %r5 : i64
    // CHECK: [eco.dbg] -2

    // -2.5 -> -3 (round away from zero)
    %neg_two_half = arith.constant -2.5 : f64
    %r6 = eco.float.round %neg_two_half : f64 -> i64
    eco.dbg %r6 : i64
    // CHECK: [eco.dbg] -3

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
