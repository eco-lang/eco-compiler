// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test float.pow with special IEEE 754 cases.
// These edge cases have specific behaviors defined by the standard.

module {
  func.func @main() -> i64 {
    %zero = arith.constant 0.0 : f64
    %one = arith.constant 1.0 : f64
    %neg_one = arith.constant -1.0 : f64
    %two = arith.constant 2.0 : f64
    %inf = arith.constant 0x7FF0000000000000 : f64  // +Infinity
    %neg_inf = arith.constant 0xFFF0000000000000 : f64  // -Infinity
    %nan = arith.constant 0x7FF8000000000000 : f64  // NaN

    // 0^0 = 1 (by convention in most math libraries)
    %p00 = eco.float.pow %zero, %zero : f64
    eco.dbg %p00 : f64
    // CHECK: 1

    // 1^anything = 1 (including 1^NaN = 1, 1^Inf = 1)
    %p1_nan = eco.float.pow %one, %nan : f64
    eco.dbg %p1_nan : f64
    // CHECK: 1

    %p1_inf = eco.float.pow %one, %inf : f64
    eco.dbg %p1_inf : f64
    // CHECK: 1

    // anything^0 = 1 (including NaN^0 = 1, Inf^0 = 1)
    %pnan_0 = eco.float.pow %nan, %zero : f64
    eco.dbg %pnan_0 : f64
    // CHECK: 1

    %pinf_0 = eco.float.pow %inf, %zero : f64
    eco.dbg %pinf_0 : f64
    // CHECK: 1

    // 0^positive = 0
    %p0_2 = eco.float.pow %zero, %two : f64
    eco.dbg %p0_2 : f64
    // CHECK: 0

    // Inf^2 = Inf
    %pinf_2 = eco.float.pow %inf, %two : f64
    eco.dbg %pinf_2 : f64
    // CHECK: inf

    // 2^Inf = Inf
    %p2_inf = eco.float.pow %two, %inf : f64
    eco.dbg %p2_inf : f64
    // CHECK: inf

    // (-1)^Inf = 1 (absolute value is 1)
    %pn1_inf = eco.float.pow %neg_one, %inf : f64
    eco.dbg %pn1_inf : f64
    // CHECK: 1

    // (-1)^(-Inf) = 1
    %pn1_ninf = eco.float.pow %neg_one, %neg_inf : f64
    eco.dbg %pn1_ninf : f64
    // CHECK: 1

    // 2^(-Inf) = 0
    %p2_ninf = eco.float.pow %two, %neg_inf : f64
    eco.dbg %p2_ninf : f64
    // CHECK: 0

    // (-2)^2 = 4 (negative base, integer exponent)
    %neg_two = arith.constant -2.0 : f64
    %pn2_2 = eco.float.pow %neg_two, %two : f64
    eco.dbg %pn2_2 : f64
    // CHECK: 4

    %ret = arith.constant 0 : i64
    return %ret : i64
  }
}
