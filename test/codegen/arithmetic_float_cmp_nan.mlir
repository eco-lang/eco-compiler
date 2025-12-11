// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test NaN comparison behavior with ordered comparisons.
// eco.float.cmp uses ordered comparisons (OLT, OEQ, ONE, etc.)
// All ordered comparisons with NaN return false.

module {
  func.func @main() -> i64 {
    // Create NaN via 0.0/0.0
    %f0 = arith.constant 0.0 : f64
    %nan = arith.divf %f0, %f0 : f64
    %f1 = arith.constant 1.0 : f64

    // NaN < x should be false (0) - OLT
    %lt = eco.float.cmp lt %nan, %f1 : f64
    %lt_ext = arith.extui %lt : i1 to i64
    eco.dbg %lt_ext : i64
    // CHECK: 0

    // x < NaN should be false (0)
    %lt2 = eco.float.cmp lt %f1, %nan : f64
    %lt2_ext = arith.extui %lt2 : i1 to i64
    eco.dbg %lt2_ext : i64
    // CHECK: 0

    // NaN > x should be false (0) - OGT
    %gt = eco.float.cmp gt %nan, %f1 : f64
    %gt_ext = arith.extui %gt : i1 to i64
    eco.dbg %gt_ext : i64
    // CHECK: 0

    // NaN <= x should be false (0) - OLE
    %le = eco.float.cmp le %nan, %f1 : f64
    %le_ext = arith.extui %le : i1 to i64
    eco.dbg %le_ext : i64
    // CHECK: 0

    // NaN >= x should be false (0) - OGE
    %ge = eco.float.cmp ge %nan, %f1 : f64
    %ge_ext = arith.extui %ge : i1 to i64
    eco.dbg %ge_ext : i64
    // CHECK: 0

    // NaN == x should be false (0) - OEQ
    %eq = eco.float.cmp eq %nan, %f1 : f64
    %eq_ext = arith.extui %eq : i1 to i64
    eco.dbg %eq_ext : i64
    // CHECK: 0

    // NaN == NaN should be false (0) - NaN is not equal to itself
    %eq_nan = eco.float.cmp eq %nan, %nan : f64
    %eq_nan_ext = arith.extui %eq_nan : i1 to i64
    eco.dbg %eq_nan_ext : i64
    // CHECK: 0

    // NaN != x with ordered comparison (ONE) returns false
    // (ordered comparisons return false when either operand is NaN)
    %ne = eco.float.cmp ne %nan, %f1 : f64
    %ne_ext = arith.extui %ne : i1 to i64
    eco.dbg %ne_ext : i64
    // CHECK: 0

    // NaN != NaN also returns false with ONE
    %ne_nan = eco.float.cmp ne %nan, %nan : f64
    %ne_nan_ext = arith.extui %ne_nan : i1 to i64
    eco.dbg %ne_nan_ext : i64
    // CHECK: 0

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
