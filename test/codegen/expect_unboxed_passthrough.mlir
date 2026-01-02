// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test eco.expect with unboxed passthrough types (i64, f64, i16).

module {
  func.func @main() -> i64 {
    %msg = eco.string_literal "should not crash" : !eco.value
    %true_cond = arith.constant 1 : i1

    // Test with i64 passthrough
    %i42 = arith.constant 42 : i64
    %result_i64 = eco.expect %true_cond, %msg, %i42 : i64 -> i64
    eco.dbg %result_i64 : i64
    // CHECK: 42

    // Test with negative i64
    %neg100 = arith.constant -100 : i64
    %result_neg = eco.expect %true_cond, %msg, %neg100 : i64 -> i64
    eco.dbg %result_neg : i64
    // CHECK: -100

    // Test with f64 passthrough
    %fpi = arith.constant 3.14159 : f64
    %result_f64 = eco.expect %true_cond, %msg, %fpi : f64 -> f64
    eco.dbg %result_f64 : f64
    // CHECK: 3.14159

    // Test with negative float
    %neg_float = arith.constant -2.5 : f64
    %result_neg_f = eco.expect %true_cond, %msg, %neg_float : f64 -> f64
    eco.dbg %result_neg_f : f64
    // CHECK: -2.5

    // Test with i16 (char) passthrough
    %charA = arith.constant 65 : i16
    %result_char = eco.expect %true_cond, %msg, %charA : i16 -> i16
    eco.dbg %result_char : i16
    // CHECK: 'A'

    // Test with zero values
    %zero_i64 = arith.constant 0 : i64
    %result_zero = eco.expect %true_cond, %msg, %zero_i64 : i64 -> i64
    eco.dbg %result_zero : i64
    // CHECK: 0

    %zero_f64 = arith.constant 0.0 : f64
    %result_zero_f = eco.expect %true_cond, %msg, %zero_f64 : f64 -> f64
    eco.dbg %result_zero_f : f64
    // CHECK: 0

    // Test chained expects
    %chain1 = eco.expect %true_cond, %msg, %i42 : i64 -> i64
    %chain2 = eco.expect %true_cond, %msg, %chain1 : i64 -> i64
    %chain3 = eco.expect %true_cond, %msg, %chain2 : i64 -> i64
    eco.dbg %chain3 : i64
    // CHECK: 42

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
