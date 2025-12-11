// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test float comparisons with NaN using different predicates.
// IEEE 754: NaN comparisons should return false for ordered comparisons,
// true for unordered comparisons.

module {
  func.func @main() -> i64 {
    // Create NaN
    %zero = arith.constant 0.0 : f64
    %nan = arith.divf %zero, %zero : f64
    %one = arith.constant 1.0 : f64

    // Ordered comparisons with NaN should return false
    // eco.float.cmp uses ordered comparisons by default

    // NaN < 1.0 - should be false (ordered)
    %lt = eco.float.cmp lt %nan, %one : f64
    %lt_i64 = arith.extui %lt : i1 to i64
    eco.dbg %lt_i64 : i64
    // CHECK: 0

    // NaN > 1.0 - should be false (ordered)
    %gt = eco.float.cmp gt %nan, %one : f64
    %gt_i64 = arith.extui %gt : i1 to i64
    eco.dbg %gt_i64 : i64
    // CHECK: 0

    // NaN == NaN - should be false (ordered)
    %eq = eco.float.cmp eq %nan, %nan : f64
    %eq_i64 = arith.extui %eq : i1 to i64
    eco.dbg %eq_i64 : i64
    // CHECK: 0

    // NaN != NaN - for ORDERED ne (ONE), returns false when NaN involved
    // This is correct IEEE 754 behavior for ordered comparisons
    %ne = eco.float.cmp ne %nan, %nan : f64
    %ne_i64 = arith.extui %ne : i1 to i64
    eco.dbg %ne_i64 : i64
    // CHECK: 0

    // NaN <= 1.0 - should be false
    %le = eco.float.cmp le %nan, %one : f64
    %le_i64 = arith.extui %le : i1 to i64
    eco.dbg %le_i64 : i64
    // CHECK: 0

    // NaN >= 1.0 - should be false
    %ge = eco.float.cmp ge %nan, %one : f64
    %ge_i64 = arith.extui %ge : i1 to i64
    eco.dbg %ge_i64 : i64
    // CHECK: 0

    // 1.0 < NaN - should be false
    %lt2 = eco.float.cmp lt %one, %nan : f64
    %lt2_i64 = arith.extui %lt2 : i1 to i64
    eco.dbg %lt2_i64 : i64
    // CHECK: 0

    // Normal comparison for sanity check: 1.0 < 2.0
    %two = arith.constant 2.0 : f64
    %normal = eco.float.cmp lt %one, %two : f64
    %normal_i64 = arith.extui %normal : i1 to i64
    eco.dbg %normal_i64 : i64
    // CHECK: 1

    %ret = arith.constant 0 : i64
    return %ret : i64
  }
}
