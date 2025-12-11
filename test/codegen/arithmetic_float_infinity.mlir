// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test Infinity behavior in float arithmetic.

module {
  func.func @main() -> i64 {
    %f0 = arith.constant 0.0 : f64
    %f1 = arith.constant 1.0 : f64
    %f2 = arith.constant 2.0 : f64
    %neg1 = arith.constant -1.0 : f64

    // 1.0 / 0.0 = +Inf
    %pos_inf = eco.float.div %f1, %f0 : f64
    eco.dbg %pos_inf : f64
    // CHECK: inf

    // -1.0 / 0.0 = -Inf
    %neg_inf = eco.float.div %neg1, %f0 : f64
    eco.dbg %neg_inf : f64
    // CHECK: -inf

    // Inf + x = Inf
    %inf_add = eco.float.add %pos_inf, %f1 : f64
    eco.dbg %inf_add : f64
    // CHECK: inf

    // Inf - x = Inf
    %inf_sub = eco.float.sub %pos_inf, %f1 : f64
    eco.dbg %inf_sub : f64
    // CHECK: inf

    // Inf * positive = Inf
    %inf_mul = eco.float.mul %pos_inf, %f2 : f64
    eco.dbg %inf_mul : f64
    // CHECK: inf

    // Inf * negative = -Inf
    %inf_mul_neg = eco.float.mul %pos_inf, %neg1 : f64
    eco.dbg %inf_mul_neg : f64
    // CHECK: -inf

    // Inf / x = Inf
    %inf_div = eco.float.div %pos_inf, %f2 : f64
    eco.dbg %inf_div : f64
    // CHECK: inf

    // x / Inf = 0
    %div_inf = eco.float.div %f1, %pos_inf : f64
    eco.dbg %div_inf : f64
    // CHECK: 0

    // Inf - Inf = NaN
    %inf_minus_inf = eco.float.sub %pos_inf, %pos_inf : f64
    eco.dbg %inf_minus_inf : f64
    // CHECK: nan

    // Inf / Inf = NaN
    %inf_div_inf = eco.float.div %pos_inf, %pos_inf : f64
    eco.dbg %inf_div_inf : f64
    // CHECK: nan

    // abs(-Inf) = Inf
    %abs_neg_inf = eco.float.abs %neg_inf : f64
    eco.dbg %abs_neg_inf : f64
    // CHECK: inf

    // negate(Inf) = -Inf
    %neg_pos_inf = eco.float.negate %pos_inf : f64
    eco.dbg %neg_pos_inf : f64
    // CHECK: -inf

    // sqrt(Inf) = Inf
    %sqrt_inf = eco.float.sqrt %pos_inf : f64
    eco.dbg %sqrt_inf : f64
    // CHECK: inf

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
