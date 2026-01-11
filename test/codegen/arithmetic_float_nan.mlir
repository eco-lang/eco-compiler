// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test NaN behavior in float arithmetic.
// NaN propagates through arithmetic operations.

module {
  func.func @main() -> i64 {
    // Create NaN via 0.0/0.0
    %f0 = arith.constant 0.0 : f64
    %nan = arith.divf %f0, %f0 : f64

    %f1 = arith.constant 1.0 : f64
    %f2 = arith.constant 2.0 : f64

    // NaN + x = NaN
    %nan_add = eco.float.add %nan, %f1 : f64
    eco.dbg %nan_add : f64
    // CHECK: NaN

    // x + NaN = NaN
    %add_nan = eco.float.add %f1, %nan : f64
    eco.dbg %add_nan : f64
    // CHECK: NaN

    // NaN - x = NaN
    %nan_sub = eco.float.sub %nan, %f1 : f64
    eco.dbg %nan_sub : f64
    // CHECK: NaN

    // NaN * x = NaN
    %nan_mul = eco.float.mul %nan, %f2 : f64
    eco.dbg %nan_mul : f64
    // CHECK: NaN

    // NaN / x = NaN
    %nan_div = eco.float.div %nan, %f2 : f64
    eco.dbg %nan_div : f64
    // CHECK: NaN

    // x / NaN = NaN
    %div_nan = eco.float.div %f1, %nan : f64
    eco.dbg %div_nan : f64
    // CHECK: NaN

    // abs(NaN) = NaN
    %abs_nan = eco.float.abs %nan : f64
    eco.dbg %abs_nan : f64
    // CHECK: NaN

    // negate(NaN) = NaN (sign bit changes but it's still NaN)
    %neg_nan = eco.float.negate %nan : f64
    eco.dbg %neg_nan : f64
    // CHECK: NaN

    // sqrt(NaN) = NaN
    %sqrt_nan = eco.float.sqrt %nan : f64
    eco.dbg %sqrt_nan : f64
    // CHECK: NaN

    // sqrt(-1) = NaN (complex result)
    %neg1 = arith.constant -1.0 : f64
    %sqrt_neg = eco.float.sqrt %neg1 : f64
    eco.dbg %sqrt_neg : f64
    // CHECK: NaN

    // pow(NaN, x) = NaN
    %pow_nan = eco.float.pow %nan, %f2 : f64
    eco.dbg %pow_nan : f64
    // CHECK: NaN

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
