// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test float min/max with special values (NaN, Infinity, zero signs).
// Uses IEEE 754 minNum/maxNum semantics.

module {
  func.func @main() -> i64 {
    %f0 = arith.constant 0.0 : f64
    %f1 = arith.constant 1.0 : f64
    %f5 = arith.constant 5.0 : f64
    %neg1 = arith.constant -1.0 : f64

    // Create special values
    %nan = arith.divf %f0, %f0 : f64
    %pos_inf = eco.float.div %f1, %f0 : f64
    %neg_inf = eco.float.div %neg1, %f0 : f64
    %neg0 = arith.constant -0.0 : f64

    // min(NaN, x) = x (minNum semantics)
    %min_nan_x = eco.float.min %nan, %f5 : f64
    eco.dbg %min_nan_x : f64
    // CHECK: 5

    // min(x, NaN) = x
    %min_x_nan = eco.float.min %f5, %nan : f64
    eco.dbg %min_x_nan : f64
    // CHECK: 5

    // max(NaN, x) = x (maxNum semantics)
    %max_nan_x = eco.float.max %nan, %f5 : f64
    eco.dbg %max_nan_x : f64
    // CHECK: 5

    // max(x, NaN) = x
    %max_x_nan = eco.float.max %f5, %nan : f64
    eco.dbg %max_x_nan : f64
    // CHECK: 5

    // min(+Inf, x) = x
    %min_inf_x = eco.float.min %pos_inf, %f5 : f64
    eco.dbg %min_inf_x : f64
    // CHECK: 5

    // max(+Inf, x) = +Inf
    %max_inf_x = eco.float.max %pos_inf, %f5 : f64
    eco.dbg %max_inf_x : f64
    // CHECK: inf

    // min(-Inf, x) = -Inf
    %min_neg_inf_x = eco.float.min %neg_inf, %f5 : f64
    eco.dbg %min_neg_inf_x : f64
    // CHECK: -inf

    // max(-Inf, x) = x
    %max_neg_inf_x = eco.float.max %neg_inf, %f5 : f64
    eco.dbg %max_neg_inf_x : f64
    // CHECK: 5

    // min(+Inf, -Inf) = -Inf
    %min_inf_inf = eco.float.min %pos_inf, %neg_inf : f64
    eco.dbg %min_inf_inf : f64
    // CHECK: -inf

    // max(+Inf, -Inf) = +Inf
    %max_inf_inf = eco.float.max %pos_inf, %neg_inf : f64
    eco.dbg %max_inf_inf : f64
    // CHECK: inf

    // min(+0.0, -0.0) behavior (IEEE 754: either is valid)
    // LLVM minnum typically returns -0.0
    %min_zeros = eco.float.min %f0, %neg0 : f64
    eco.dbg %min_zeros : f64
    // CHECK: 0

    // max(+0.0, -0.0) behavior (IEEE 754: either is valid)
    %max_zeros = eco.float.max %f0, %neg0 : f64
    eco.dbg %max_zeros : f64
    // CHECK: 0

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
