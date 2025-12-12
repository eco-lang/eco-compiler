// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test min/max behavior with NaN operands.
// IEEE 754 minNum/maxNum: when one operand is NaN, return the non-NaN value.
// When both are NaN, behavior is implementation-defined (usually returns NaN).
//
// Note: Testing NaN via comparison doesn't work because eco.float.cmp
// uses ordered comparisons where even 'ne' returns false for NaN.

module {
  func.func @main() -> i64 {
    %nan = arith.constant 0x7FF8000000000000 : i64
    %nan_f = arith.bitcast %nan : i64 to f64
    %c1 = arith.constant 1.0 : f64
    %c5 = arith.constant 5.0 : f64

    // min(1.0, NaN) with minNum semantics returns 1.0
    %min_one_nan = eco.float.min %c1, %nan_f : f64
    %min_eq_one = eco.float.cmp eq %min_one_nan, %c1 : f64
    %min_eq_i = arith.extui %min_eq_one : i1 to i64
    eco.dbg %min_eq_i : i64
    // CHECK: [eco.dbg] 1

    // max(5.0, NaN) with maxNum semantics returns 5.0
    %max_five_nan = eco.float.max %c5, %nan_f : f64
    %max_eq_five = eco.float.cmp eq %max_five_nan, %c5 : f64
    %max_eq_i = arith.extui %max_eq_five : i1 to i64
    eco.dbg %max_eq_i : i64
    // CHECK: [eco.dbg] 1

    // min(NaN, 1.0) - same result due to symmetry
    %min_nan_one = eco.float.min %nan_f, %c1 : f64
    %min2_eq_one = eco.float.cmp eq %min_nan_one, %c1 : f64
    %min2_eq_i = arith.extui %min2_eq_one : i1 to i64
    eco.dbg %min2_eq_i : i64
    // CHECK: [eco.dbg] 1

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
