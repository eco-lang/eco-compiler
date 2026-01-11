// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test float comparison with -0.0 and +0.0 (IEEE 754: -0.0 == +0.0).

module {
  func.func @main() -> i64 {
    %pos_zero = arith.constant 0.0 : f64
    %neg_zero = arith.constant -0.0 : f64
    %one = arith.constant 1.0 : f64

    // Test: -0.0 == +0.0 should be true (IEEE 754)
    %eq1 = eco.float.eq %neg_zero, %pos_zero : f64
    %eq1_ext = arith.extui %eq1 : i1 to i64
    eco.dbg %eq1_ext : i64
    // CHECK: 1

    // Test: +0.0 == -0.0 should be true (commutative)
    %eq2 = eco.float.eq %pos_zero, %neg_zero : f64
    %eq2_ext = arith.extui %eq2 : i1 to i64
    eco.dbg %eq2_ext : i64
    // CHECK: 1

    // Test: -0.0 != +0.0 should be false
    %ne1 = eco.float.ne %neg_zero, %pos_zero : f64
    %ne1_ext = arith.extui %ne1 : i1 to i64
    eco.dbg %ne1_ext : i64
    // CHECK: 0

    // Test: -0.0 < +0.0 should be false
    %lt1 = eco.float.lt %neg_zero, %pos_zero : f64
    %lt1_ext = arith.extui %lt1 : i1 to i64
    eco.dbg %lt1_ext : i64
    // CHECK: 0

    // Test: +0.0 < -0.0 should be false
    %lt2 = eco.float.lt %pos_zero, %neg_zero : f64
    %lt2_ext = arith.extui %lt2 : i1 to i64
    eco.dbg %lt2_ext : i64
    // CHECK: 0

    // Test: -0.0 <= +0.0 should be true
    %le1 = eco.float.le %neg_zero, %pos_zero : f64
    %le1_ext = arith.extui %le1 : i1 to i64
    eco.dbg %le1_ext : i64
    // CHECK: 1

    // Test: -0.0 >= +0.0 should be true
    %ge1 = eco.float.ge %neg_zero, %pos_zero : f64
    %ge1_ext = arith.extui %ge1 : i1 to i64
    eco.dbg %ge1_ext : i64
    // CHECK: 1

    // But -0.0 and +0.0 are distinguishable via other means
    // Division: 1.0 / +0.0 = +Inf, 1.0 / -0.0 = -Inf
    %div_pos = eco.float.div %one, %pos_zero : f64
    %div_neg = eco.float.div %one, %neg_zero : f64
    eco.dbg %div_pos : f64
    // CHECK: Infinity
    eco.dbg %div_neg : f64
    // CHECK: -Infinity

    // min/max with zeros
    %min_zeros = eco.float.min %neg_zero, %pos_zero : f64
    %max_zeros = eco.float.max %neg_zero, %pos_zero : f64
    // Both should be zero (exact bit pattern may vary)
    %min_eq_zero = eco.float.eq %min_zeros, %pos_zero : f64
    %max_eq_zero = eco.float.eq %max_zeros, %pos_zero : f64
    %min_eq_ext = arith.extui %min_eq_zero : i1 to i64
    %max_eq_ext = arith.extui %max_eq_zero : i1 to i64
    eco.dbg %min_eq_ext : i64
    // CHECK: 1
    eco.dbg %max_eq_ext : i64
    // CHECK: 1

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
