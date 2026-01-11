// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test eco.expect with f64 passthrough.
// Verifies unboxed float passthrough in expect operation.

module {
  func.func @main() -> i64 {
    %msg = eco.string_literal "should not see this" : !eco.value

    // Test with passing condition and f64 passthrough
    %pi = arith.constant 3.14159 : f64
    %cond_true = arith.constant true
    %result1 = eco.expect %cond_true, %msg, %pi : f64 -> f64
    eco.dbg %result1 : f64
    // CHECK: 3.14159

    // Test with different float value
    %e = arith.constant 2.71828 : f64
    %result2 = eco.expect %cond_true, %msg, %e : f64 -> f64
    eco.dbg %result2 : f64
    // CHECK: 2.71828

    // Test with negative float
    %neg = arith.constant -42.5 : f64
    %result3 = eco.expect %cond_true, %msg, %neg : f64 -> f64
    eco.dbg %result3 : f64
    // CHECK: -42.5

    // Test with infinity
    %inf = arith.constant 0x7FF0000000000000 : f64
    %result4 = eco.expect %cond_true, %msg, %inf : f64 -> f64
    eco.dbg %result4 : f64
    // CHECK: Infinity

    // Test with zero
    %zero_f = arith.constant 0.0 : f64
    %result5 = eco.expect %cond_true, %msg, %zero_f : f64 -> f64
    eco.dbg %result5 : f64
    // CHECK: 0

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
