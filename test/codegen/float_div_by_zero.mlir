// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test float division by zero (returns Inf/NaN per IEEE 754).

module {
  func.func @main() -> i64 {
    %zero_f = arith.constant 0.0 : f64
    %one = arith.constant 1.0 : f64
    %neg_one = arith.constant -1.0 : f64
    %five = arith.constant 5.0 : f64

    // 1.0 / 0.0 = +Inf
    %pos_inf = eco.float.div %one, %zero_f : f64
    // Check it's greater than any finite number
    %million = arith.constant 1000000.0 : f64
    %is_huge = eco.float.cmp gt %pos_inf, %million : f64
    %is_huge_ext = arith.extui %is_huge : i1 to i64
    eco.dbg %is_huge_ext : i64
    // CHECK: 1

    // -1.0 / 0.0 = -Inf
    %neg_inf = eco.float.div %neg_one, %zero_f : f64
    // Check it's less than any finite number
    %neg_million = arith.constant -1000000.0 : f64
    %is_neg_huge = eco.float.cmp lt %neg_inf, %neg_million : f64
    %is_neg_huge_ext = arith.extui %is_neg_huge : i1 to i64
    eco.dbg %is_neg_huge_ext : i64
    // CHECK: 1

    // 0.0 / 0.0 = NaN
    %nan = eco.float.div %zero_f, %zero_f : f64
    // NaN == NaN is false (ordered comparison)
    %is_nan = eco.float.cmp eq %nan, %nan : f64
    %is_nan_ext = arith.extui %is_nan : i1 to i64
    eco.dbg %is_nan_ext : i64
    // CHECK: 0

    // 5.0 / 0.0 = +Inf
    %pos_inf2 = eco.float.div %five, %zero_f : f64
    %is_huge2 = eco.float.cmp gt %pos_inf2, %million : f64
    %is_huge2_ext = arith.extui %is_huge2 : i1 to i64
    eco.dbg %is_huge2_ext : i64
    // CHECK: 1

    // Inf + Inf = Inf
    %inf_sum = eco.float.add %pos_inf, %pos_inf2 : f64
    %is_inf = eco.float.cmp eq %inf_sum, %pos_inf : f64
    %is_inf_ext = arith.extui %is_inf : i1 to i64
    eco.dbg %is_inf_ext : i64
    // CHECK: 1

    // Inf - Inf = NaN
    %inf_diff = eco.float.sub %pos_inf, %pos_inf2 : f64
    %inf_diff_is_nan = eco.float.cmp eq %inf_diff, %inf_diff : f64
    %inf_diff_nan_ext = arith.extui %inf_diff_is_nan : i1 to i64
    eco.dbg %inf_diff_nan_ext : i64
    // CHECK: 0

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
