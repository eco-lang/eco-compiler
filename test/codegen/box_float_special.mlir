// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test floating-point boxing with various values.

module {
  func.func @main() -> i64 {
    // Zero
    %f0 = arith.constant 0.0 : f64
    %b0 = eco.box %f0 : f64 -> !eco.value
    eco.dbg %b0 : !eco.value
    // CHECK: 0

    // Negative zero (should print as 0 or -0)
    %f1 = arith.constant -0.0 : f64
    %b1 = eco.box %f1 : f64 -> !eco.value
    eco.dbg %b1 : !eco.value
    // CHECK: 0

    // Common value: pi
    %f2 = arith.constant 3.14159 : f64
    %b2 = eco.box %f2 : f64 -> !eco.value
    eco.dbg %b2 : !eco.value
    // CHECK: 3.14159

    // Negative float
    %f3 = arith.constant -2.71828 : f64
    %b3 = eco.box %f3 : f64 -> !eco.value
    eco.dbg %b3 : !eco.value
    // CHECK: -2.71828

    // Small positive
    %f4 = arith.constant 0.001 : f64
    %b4 = eco.box %f4 : f64 -> !eco.value
    eco.dbg %b4 : !eco.value
    // CHECK: 0.001

    // Integer stored as float
    %f5 = arith.constant 42.0 : f64
    %b5 = eco.box %f5 : f64 -> !eco.value
    eco.dbg %b5 : !eco.value
    // CHECK: 42

    // Large float
    %f6 = arith.constant 1.0e10 : f64
    %b6 = eco.box %f6 : f64 -> !eco.value
    eco.dbg %b6 : !eco.value
    // CHECK: 1e+10

    // Small scientific notation
    %f7 = arith.constant 1.5e-5 : f64
    %b7 = eco.box %f7 : f64 -> !eco.value
    eco.dbg %b7 : !eco.value
    // CHECK: 1.5e-05

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
