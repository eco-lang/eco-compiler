// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test eco.dbg with multiple arguments (variadic debugging).

module {
  func.func @main() -> i64 {
    %i10 = arith.constant 10 : i64
    %i20 = arith.constant 20 : i64
    %i30 = arith.constant 30 : i64
    %f1_5 = arith.constant 1.5 : f64
    %f2_5 = arith.constant 2.5 : f64
    %true_val = arith.constant true
    %false_val = arith.constant false

    // Single argument (baseline)
    eco.dbg %i10 : i64
    // CHECK: 10

    // Two i64 arguments
    eco.dbg %i10, %i20 : i64, i64
    // CHECK: 10
    // CHECK: 20

    // Three i64 arguments
    eco.dbg %i10, %i20, %i30 : i64, i64, i64
    // CHECK: 10
    // CHECK: 20
    // CHECK: 30

    // Mixed types: i64 and f64
    eco.dbg %i10, %f1_5 : i64, f64
    // CHECK: 10
    // CHECK: 1.5

    // Multiple f64
    eco.dbg %f1_5, %f2_5 : f64, f64
    // CHECK: 1.5
    // CHECK: 2.5

    // Bool arguments - extend to i64 first
    %true_ext = arith.extui %true_val : i1 to i64
    %false_ext = arith.extui %false_val : i1 to i64
    eco.dbg %true_ext, %false_ext : i64, i64
    // CHECK: 1
    // CHECK: 0

    // Mixed i64, f64
    eco.dbg %i10, %f1_5, %i20 : i64, f64, i64
    // CHECK: 10
    // CHECK: 1.5
    // CHECK: 20

    // Boxed values
    %b10 = eco.box %i10 : i64 -> !eco.value
    %b20 = eco.box %i20 : i64 -> !eco.value
    eco.dbg %b10, %b20 : !eco.value, !eco.value
    // CHECK: 10
    // CHECK: 20

    // Mixed boxed and unboxed
    eco.dbg %i30, %b10 : i64, !eco.value
    // CHECK: 30
    // CHECK: 10

    // String literals
    %s1 = eco.string_literal "first" : !eco.value
    %s2 = eco.string_literal "second" : !eco.value
    eco.dbg %s1, %s2 : !eco.value, !eco.value
    // CHECK: "first"
    // CHECK: "second"

    // Four arguments
    eco.dbg %i10, %i20, %i30, %f1_5 : i64, i64, i64, f64
    // CHECK: 10
    // CHECK: 20
    // CHECK: 30
    // CHECK: 1.5

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
