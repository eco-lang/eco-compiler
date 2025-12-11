// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test all comparison predicates with equal operands.

module {
  func.func @main() -> i64 {
    %i5 = arith.constant 5 : i64
    %i5_copy = arith.constant 5 : i64
    %f3 = arith.constant 3.14 : f64
    %f3_copy = arith.constant 3.14 : f64

    // Integer comparisons with equal values

    // 5 == 5 -> true
    %eq_int = eco.int.cmp eq %i5, %i5_copy : i64
    %eq_int_ext = arith.extui %eq_int : i1 to i64
    eco.dbg %eq_int_ext : i64
    // CHECK: 1

    // 5 != 5 -> false
    %ne_int = eco.int.cmp ne %i5, %i5_copy : i64
    %ne_int_ext = arith.extui %ne_int : i1 to i64
    eco.dbg %ne_int_ext : i64
    // CHECK: 0

    // 5 < 5 -> false
    %lt_int = eco.int.cmp lt %i5, %i5_copy : i64
    %lt_int_ext = arith.extui %lt_int : i1 to i64
    eco.dbg %lt_int_ext : i64
    // CHECK: 0

    // 5 <= 5 -> true
    %le_int = eco.int.cmp le %i5, %i5_copy : i64
    %le_int_ext = arith.extui %le_int : i1 to i64
    eco.dbg %le_int_ext : i64
    // CHECK: 1

    // 5 > 5 -> false
    %gt_int = eco.int.cmp gt %i5, %i5_copy : i64
    %gt_int_ext = arith.extui %gt_int : i1 to i64
    eco.dbg %gt_int_ext : i64
    // CHECK: 0

    // 5 >= 5 -> true
    %ge_int = eco.int.cmp ge %i5, %i5_copy : i64
    %ge_int_ext = arith.extui %ge_int : i1 to i64
    eco.dbg %ge_int_ext : i64
    // CHECK: 1

    // Float comparisons with equal values

    // 3.14 == 3.14 -> true
    %eq_float = eco.float.cmp eq %f3, %f3_copy : f64
    %eq_float_ext = arith.extui %eq_float : i1 to i64
    eco.dbg %eq_float_ext : i64
    // CHECK: 1

    // 3.14 != 3.14 -> false
    %ne_float = eco.float.cmp ne %f3, %f3_copy : f64
    %ne_float_ext = arith.extui %ne_float : i1 to i64
    eco.dbg %ne_float_ext : i64
    // CHECK: 0

    // 3.14 < 3.14 -> false
    %lt_float = eco.float.cmp lt %f3, %f3_copy : f64
    %lt_float_ext = arith.extui %lt_float : i1 to i64
    eco.dbg %lt_float_ext : i64
    // CHECK: 0

    // 3.14 <= 3.14 -> true
    %le_float = eco.float.cmp le %f3, %f3_copy : f64
    %le_float_ext = arith.extui %le_float : i1 to i64
    eco.dbg %le_float_ext : i64
    // CHECK: 1

    // 3.14 > 3.14 -> false
    %gt_float = eco.float.cmp gt %f3, %f3_copy : f64
    %gt_float_ext = arith.extui %gt_float : i1 to i64
    eco.dbg %gt_float_ext : i64
    // CHECK: 0

    // 3.14 >= 3.14 -> true
    %ge_float = eco.float.cmp ge %f3, %f3_copy : f64
    %ge_float_ext = arith.extui %ge_float : i1 to i64
    eco.dbg %ge_float_ext : i64
    // CHECK: 1

    // min/max with equal values
    %min_eq = eco.int.min %i5, %i5_copy : i64
    eco.dbg %min_eq : i64
    // CHECK: 5

    %max_eq = eco.int.max %i5, %i5_copy : i64
    eco.dbg %max_eq : i64
    // CHECK: 5

    %fmin_eq = eco.float.min %f3, %f3_copy : f64
    eco.dbg %fmin_eq : f64
    // CHECK: 3.14

    %fmax_eq = eco.float.max %f3, %f3_copy : f64
    eco.dbg %fmax_eq : f64
    // CHECK: 3.14

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
