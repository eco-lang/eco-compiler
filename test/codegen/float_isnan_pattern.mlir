// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test NaN detection and floating point comparison behavior.
// Note: eco.float.cmp uses ordered comparisons, so NaN != NaN returns false.
// (IEEE 754 specifies NaN != NaN should be true with unordered comparison)

module {
  func.func @main() -> i64 {
    // Create NaN via 0.0 / 0.0
    %zero_f = arith.constant 0.0 : f64
    %nan = eco.float.div %zero_f, %zero_f : f64
    eco.dbg %nan : f64
    // CHECK: nan

    // NaN == NaN: ordered comparison returns false (correct)
    %nan_eq_nan = eco.float.cmp eq %nan, %nan : f64
    %nan_eq_ext = arith.extui %nan_eq_nan : i1 to i64
    eco.dbg %nan_eq_ext : i64
    // CHECK: 0

    // Regular values: x == x is true
    %one = arith.constant 1.0 : f64
    %one_eq_one = eco.float.cmp eq %one, %one : f64
    %one_eq_ext = arith.extui %one_eq_one : i1 to i64
    eco.dbg %one_eq_ext : i64
    // CHECK: 1

    %one_ne_one = eco.float.cmp ne %one, %one : f64
    %one_ne_ext = arith.extui %one_ne_one : i1 to i64
    eco.dbg %one_ne_ext : i64
    // CHECK: 0

    // Infinity: inf == inf is true
    %inf = eco.float.div %one, %zero_f : f64
    %inf_eq_inf = eco.float.cmp eq %inf, %inf : f64
    %inf_eq_ext = arith.extui %inf_eq_inf : i1 to i64
    eco.dbg %inf_eq_ext : i64
    // CHECK: 1

    %inf_ne_inf = eco.float.cmp ne %inf, %inf : f64
    %inf_ne_ext = arith.extui %inf_ne_inf : i1 to i64
    eco.dbg %inf_ne_ext : i64
    // CHECK: 0

    // -0.0 == -0.0 is true
    %neg_zero = arith.constant -0.0 : f64
    %nz_eq_nz = eco.float.cmp eq %neg_zero, %neg_zero : f64
    %nz_eq_ext = arith.extui %nz_eq_nz : i1 to i64
    eco.dbg %nz_eq_ext : i64
    // CHECK: 1

    // NaN compared to regular value: all ordered comparisons fail
    %nan_eq_one = eco.float.cmp eq %nan, %one : f64
    %nan_eq_one_ext = arith.extui %nan_eq_one : i1 to i64
    eco.dbg %nan_eq_one_ext : i64
    // CHECK: 0

    // All ordering comparisons with NaN are false
    %nan_lt_one = eco.float.cmp lt %nan, %one : f64
    %nan_lt_ext = arith.extui %nan_lt_one : i1 to i64
    eco.dbg %nan_lt_ext : i64
    // CHECK: 0

    %nan_le_one = eco.float.cmp le %nan, %one : f64
    %nan_le_ext = arith.extui %nan_le_one : i1 to i64
    eco.dbg %nan_le_ext : i64
    // CHECK: 0

    %nan_gt_one = eco.float.cmp gt %nan, %one : f64
    %nan_gt_ext = arith.extui %nan_gt_one : i1 to i64
    eco.dbg %nan_gt_ext : i64
    // CHECK: 0

    %nan_ge_one = eco.float.cmp ge %nan, %one : f64
    %nan_ge_ext = arith.extui %nan_ge_one : i1 to i64
    eco.dbg %nan_ge_ext : i64
    // CHECK: 0

    // Verify infinity comparisons
    %inf_gt_one = eco.float.cmp gt %inf, %one : f64
    %inf_gt_ext = arith.extui %inf_gt_one : i1 to i64
    eco.dbg %inf_gt_ext : i64
    // CHECK: 1

    %neg_inf = eco.float.negate %inf : f64
    %neg_inf_lt_one = eco.float.cmp lt %neg_inf, %one : f64
    %neg_inf_lt_ext = arith.extui %neg_inf_lt_one : i1 to i64
    eco.dbg %neg_inf_lt_ext : i64
    // CHECK: 1

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
