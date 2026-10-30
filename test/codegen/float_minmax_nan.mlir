// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test eco.float.min/max with NaN arguments.
// IEEE 754-2019 minimum / maximum (CGEN_086): a NaN in either argument gives NaN.

module {
  func.func @main() -> i64 {
    %zero_f = arith.constant 0.0 : f64
    %one = arith.constant 1.0 : f64
    %five = arith.constant 5.0 : f64
    %ten = arith.constant 10.0 : f64

    // Create NaN via 0/0
    %nan = arith.divf %zero_f, %zero_f : f64

    // min(5, 10) = 5
    %min1 = eco.float.min %five, %ten : f64
    %is_five = eco.float.eq %min1, %five : f64
    %is_five_ext = arith.extui %is_five : i1 to i64
    eco.dbg %is_five_ext : i64
    // CHECK: 1

    // max(5, 10) = 10
    %max1 = eco.float.max %five, %ten : f64
    %is_ten = eco.float.eq %max1, %ten : f64
    %is_ten_ext = arith.extui %is_ten : i1 to i64
    eco.dbg %is_ten_ext : i64
    // CHECK: 1

    // min(NaN, 5) = NaN (NaN propagates)
    %min_nan_first = eco.float.min %nan, %five : f64
    %min_first_is_nan = eco.float.isNaN %min_nan_first : f64
    %min_first_is_nan_ext = arith.extui %min_first_is_nan : i1 to i64
    eco.dbg %min_first_is_nan_ext : i64
    // CHECK: 1

    // min(5, NaN) = NaN (NaN propagates)
    %min_nan_second = eco.float.min %five, %nan : f64
    %min_second_is_nan = eco.float.isNaN %min_nan_second : f64
    %min_second_is_nan_ext = arith.extui %min_second_is_nan : i1 to i64
    eco.dbg %min_second_is_nan_ext : i64
    // CHECK: 1

    // max(NaN, 5) = NaN (NaN propagates)
    %max_nan_first = eco.float.max %nan, %five : f64
    %max_first_is_nan = eco.float.isNaN %max_nan_first : f64
    %max_first_is_nan_ext = arith.extui %max_first_is_nan : i1 to i64
    eco.dbg %max_first_is_nan_ext : i64
    // CHECK: 1

    // max(5, NaN) = NaN (NaN propagates)
    %max_nan_second = eco.float.max %five, %nan : f64
    %max_second_is_nan = eco.float.isNaN %max_nan_second : f64
    %max_second_is_nan_ext = arith.extui %max_second_is_nan : i1 to i64
    eco.dbg %max_second_is_nan_ext : i64
    // CHECK: 1

    // min(NaN, NaN) = NaN
    %min_nan_nan = eco.float.min %nan, %nan : f64
    %min_is_nan = eco.float.eq %min_nan_nan, %min_nan_nan : f64
    %min_is_nan_ext = arith.extui %min_is_nan : i1 to i64
    eco.dbg %min_is_nan_ext : i64
    // CHECK: 0

    // max(NaN, NaN) = NaN
    %max_nan_nan = eco.float.max %nan, %nan : f64
    %max_is_nan = eco.float.eq %max_nan_nan, %max_nan_nan : f64
    %max_is_nan_ext = arith.extui %max_is_nan : i1 to i64
    eco.dbg %max_is_nan_ext : i64
    // CHECK: 0

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
