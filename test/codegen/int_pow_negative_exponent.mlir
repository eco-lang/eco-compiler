// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test eco.int.pow with negative exponent.
// A negative exponent gives the truncation of the real result (The Definition of Standard Elm,
// ruling A43): 1 for base 1, 1 or -1 for base -1 by the parity of the exponent, and 0 for every
// other base (2^(-1) = 0.5 truncates to 0).

module {
  func.func @main() -> i64 {
    %c0 = arith.constant 0 : i64
    %c1 = arith.constant 1 : i64
    %c2 = arith.constant 2 : i64
    %c3 = arith.constant 3 : i64
    %c10 = arith.constant 10 : i64
    %cn1 = arith.constant -1 : i64
    %cn2 = arith.constant -2 : i64

    // Positive exponent (baseline): 2^3 = 8
    %pow1 = eco.int.pow %c2, %c3 : i64
    eco.dbg %pow1 : i64
    // CHECK: [eco.dbg] 8

    // Zero exponent: 2^0 = 1
    %pow2 = eco.int.pow %c2, %c0 : i64
    eco.dbg %pow2 : i64
    // CHECK: [eco.dbg] 1

    // Negative exponent: 2^(-1) = 0 (0.5 truncated)
    %pow3 = eco.int.pow %c2, %cn1 : i64
    eco.dbg %pow3 : i64
    // CHECK: [eco.dbg] 0

    // Negative exponent: 10^(-2) = 0 (0.01 truncated)
    %pow4 = eco.int.pow %c10, %cn2 : i64
    eco.dbg %pow4 : i64
    // CHECK: [eco.dbg] 0

    // 1^(-5) = 1
    %cn5 = arith.constant -5 : i64
    %pow5 = eco.int.pow %c1, %cn5 : i64
    eco.dbg %pow5 : i64
    // CHECK: [eco.dbg] 1

    // (-1)^(-1) = -1 (odd exponent)
    %pow6 = eco.int.pow %cn1, %cn1 : i64
    eco.dbg %pow6 : i64
    // CHECK: [eco.dbg] -1

    // (-1)^(-2) = 1 (even exponent)
    %pow7 = eco.int.pow %cn1, %cn2 : i64
    eco.dbg %pow7 : i64
    // CHECK: [eco.dbg] 1

    // Large base with negative exponent: 1000^(-1) = 0
    %c1000 = arith.constant 1000 : i64
    %pow8 = eco.int.pow %c1000, %cn1 : i64
    eco.dbg %pow8 : i64
    // CHECK: [eco.dbg] 0

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
