// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test storing and loading floating point values in globals.
// Tests boxed float handling through global storage.

module {
  eco.global @float_global
  eco.global @negative_float
  eco.global @special_float

  func.func @main() -> i64 {
    // Store a positive float
    %f1 = arith.constant 3.14159 : f64
    %bf1 = eco.box %f1 : f64 -> !eco.value
    eco.store_global %bf1, @float_global

    %v1 = eco.load_global @float_global
    eco.dbg %v1 : !eco.value
    // CHECK: [eco.dbg] 3.14159

    // Store a negative float
    %f2 = arith.constant -273.15 : f64
    %bf2 = eco.box %f2 : f64 -> !eco.value
    eco.store_global %bf2, @negative_float

    %v2 = eco.load_global @negative_float
    eco.dbg %v2 : !eco.value
    // CHECK: [eco.dbg] -273.15

    // Store zero
    %f3 = arith.constant 0.0 : f64
    %bf3 = eco.box %f3 : f64 -> !eco.value
    eco.store_global %bf3, @special_float

    %v3 = eco.load_global @special_float
    eco.dbg %v3 : !eco.value
    // CHECK: [eco.dbg] 0

    // Overwrite with a very small number
    %f4 = arith.constant 1.0e-10 : f64
    %bf4 = eco.box %f4 : f64 -> !eco.value
    eco.store_global %bf4, @special_float

    %v4 = eco.load_global @special_float
    eco.dbg %v4 : !eco.value
    // CHECK: [eco.dbg] 1e-10

    // Verify original globals unchanged
    %check1 = eco.load_global @float_global
    eco.dbg %check1 : !eco.value
    // CHECK: [eco.dbg] 3.14159

    %check2 = eco.load_global @negative_float
    eco.dbg %check2 : !eco.value
    // CHECK: [eco.dbg] -273.15

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
