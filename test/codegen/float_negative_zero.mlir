// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test -0.0 vs +0.0 behavior per IEEE 754.
// -0.0 and +0.0 compare equal but have different bit patterns.

module {
  func.func @main() -> i64 {
    %pos_zero = arith.constant 0.0 : f64
    %neg_zero = arith.constant -0.0 : f64
    %one = arith.constant 1.0 : f64
    %neg_one = arith.constant -1.0 : f64

    // -0.0 == +0.0 should be true
    %eq = eco.float.cmp eq %pos_zero, %neg_zero : f64
    %eq_ext = arith.extui %eq : i1 to i64
    eco.dbg %eq_ext : i64
    // CHECK: 1

    // -0.0 < +0.0 should be false (they are equal)
    %lt = eco.float.cmp lt %neg_zero, %pos_zero : f64
    %lt_ext = arith.extui %lt : i1 to i64
    eco.dbg %lt_ext : i64
    // CHECK: 0

    // negate(+0.0) should give -0.0
    %negated = eco.float.negate %pos_zero : f64
    // Division by -0.0 gives -Inf, by +0.0 gives +Inf
    %div_pos = eco.float.div %one, %pos_zero : f64
    %div_neg = eco.float.div %one, %neg_zero : f64

    // 1.0 / +0.0 = +Inf (positive)
    %is_pos_inf = eco.float.cmp gt %div_pos, %one : f64
    %pos_inf_ext = arith.extui %is_pos_inf : i1 to i64
    eco.dbg %pos_inf_ext : i64
    // CHECK: 1

    // 1.0 / -0.0 = -Inf (negative)
    %is_neg_inf = eco.float.cmp lt %div_neg, %neg_one : f64
    %neg_inf_ext = arith.extui %is_neg_inf : i1 to i64
    eco.dbg %neg_inf_ext : i64
    // CHECK: 1

    // abs(-0.0) should be +0.0
    %abs_neg_zero = eco.float.abs %neg_zero : f64
    // Verify by dividing: 1.0 / abs(-0.0) should be +Inf
    %div_abs = eco.float.div %one, %abs_neg_zero : f64
    %is_pos_inf2 = eco.float.cmp gt %div_abs, %one : f64
    %pos_inf2_ext = arith.extui %is_pos_inf2 : i1 to i64
    eco.dbg %pos_inf2_ext : i64
    // CHECK: 1

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
