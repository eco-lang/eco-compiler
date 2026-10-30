// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test min/max behavior with NaN operands.
// IEEE 754-2019 minimum / maximum (CGEN_086): a NaN in either argument gives NaN.
//
// Each result is observed with eco.float.isNaN.

module {
  func.func @main() -> i64 {
    %nan = arith.constant 0x7FF8000000000000 : i64
    %nan_f = arith.bitcast %nan : i64 to f64
    %c1 = arith.constant 1.0 : f64
    %c5 = arith.constant 5.0 : f64

    // min(1.0, NaN) is NaN
    %min_one_nan = eco.float.min %c1, %nan_f : f64
    %min_is_nan = eco.float.isNaN %min_one_nan : f64
    %min_is_nan_i = arith.extui %min_is_nan : i1 to i64
    eco.dbg %min_is_nan_i : i64
    // CHECK: [eco.dbg] 1

    // max(5.0, NaN) is NaN
    %max_five_nan = eco.float.max %c5, %nan_f : f64
    %max_is_nan = eco.float.isNaN %max_five_nan : f64
    %max_is_nan_i = arith.extui %max_is_nan : i1 to i64
    eco.dbg %max_is_nan_i : i64
    // CHECK: [eco.dbg] 1

    // min(NaN, 1.0) is NaN too: the result does not depend on the argument order
    %min_nan_one = eco.float.min %nan_f, %c1 : f64
    %min2_is_nan = eco.float.isNaN %min_nan_one : f64
    %min2_is_nan_i = arith.extui %min2_is_nan : i1 to i64
    eco.dbg %min2_is_nan_i : i64
    // CHECK: [eco.dbg] 1

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
