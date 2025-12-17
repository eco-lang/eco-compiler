// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test chaining float ops: abs(negate(x)), negate(abs(x)), sqrt(abs(x)).

module {
  func.func @main() -> i64 {
    %f5 = arith.constant 5.0 : f64
    %fn5 = arith.constant -5.0 : f64
    %f16 = arith.constant 16.0 : f64
    %fn16 = arith.constant -16.0 : f64
    %f0 = arith.constant 0.0 : f64

    // abs(negate(5.0)) = abs(-5.0) = 5.0
    %neg5 = eco.float.negate %f5 : f64
    %abs_neg5 = eco.float.abs %neg5 : f64
    eco.dbg %abs_neg5 : f64
    // CHECK: 5

    // abs(negate(-5.0)) = abs(5.0) = 5.0
    %neg_neg5 = eco.float.negate %fn5 : f64
    %abs_neg_neg5 = eco.float.abs %neg_neg5 : f64
    eco.dbg %abs_neg_neg5 : f64
    // CHECK: 5

    // negate(abs(-5.0)) = negate(5.0) = -5.0
    %abs_fn5 = eco.float.abs %fn5 : f64
    %neg_abs_fn5 = eco.float.negate %abs_fn5 : f64
    eco.dbg %neg_abs_fn5 : f64
    // CHECK: -5

    // negate(abs(5.0)) = negate(5.0) = -5.0
    %abs_f5 = eco.float.abs %f5 : f64
    %neg_abs_f5 = eco.float.negate %abs_f5 : f64
    eco.dbg %neg_abs_f5 : f64
    // CHECK: -5

    // sqrt(abs(-16.0)) = sqrt(16.0) = 4.0
    %abs_fn16 = eco.float.abs %fn16 : f64
    %sqrt_abs_fn16 = eco.float.sqrt %abs_fn16 : f64
    eco.dbg %sqrt_abs_fn16 : f64
    // CHECK: 4

    // sqrt(abs(16.0)) = sqrt(16.0) = 4.0
    %abs_f16 = eco.float.abs %f16 : f64
    %sqrt_abs_f16 = eco.float.sqrt %abs_f16 : f64
    eco.dbg %sqrt_abs_f16 : f64
    // CHECK: 4

    // negate(negate(5.0)) = 5.0
    %neg_neg5_v2 = eco.float.negate %neg5 : f64
    eco.dbg %neg_neg5_v2 : f64
    // CHECK: 5

    // abs(abs(-5.0)) = abs(5.0) = 5.0 (idempotent)
    %abs_abs = eco.float.abs %abs_fn5 : f64
    eco.dbg %abs_abs : f64
    // CHECK: 5

    // Chain with zero: negate(0.0) = -0.0, abs(-0.0) = 0.0
    %neg_zero = eco.float.negate %f0 : f64
    %abs_neg_zero = eco.float.abs %neg_zero : f64
    // Check that abs(-0.0) equals 0.0
    %eq_zero = eco.float.eq %abs_neg_zero, %f0 : f64
    %eq_ext = arith.extui %eq_zero : i1 to i64
    eco.dbg %eq_ext : i64
    // CHECK: 1

    // Complex chain: sqrt(abs(negate(negate(16.0))))
    %nn16 = eco.float.negate %f16 : f64
    %nnn16 = eco.float.negate %nn16 : f64
    %abs_nnn16 = eco.float.abs %nnn16 : f64
    %sqrt_chain = eco.float.sqrt %abs_nnn16 : f64
    eco.dbg %sqrt_chain : f64
    // CHECK: 4

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
