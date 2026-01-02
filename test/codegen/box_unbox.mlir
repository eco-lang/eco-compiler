// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test eco.box and eco.unbox for primitive values.

module {
  func.func @main() -> i64 {
    // Test boxing integers
    %i42 = arith.constant 42 : i64
    %boxed_int = eco.box %i42 : i64 -> !eco.value
    eco.dbg %boxed_int : !eco.value
    // CHECK: 42

    // Test boxing negative integers
    %neg = arith.constant -123 : i64
    %boxed_neg = eco.box %neg : i64 -> !eco.value
    eco.dbg %boxed_neg : !eco.value
    // CHECK: -123

    // Test boxing floats
    %f = arith.constant 3.14159 : f64
    %boxed_float = eco.box %f : f64 -> !eco.value
    eco.dbg %boxed_float : !eco.value
    // CHECK: 3.14159

    // Test boxing characters
    %c = arith.constant 65 : i16  // 'A'
    %boxed_char = eco.box %c : i16 -> !eco.value
    eco.dbg %boxed_char : !eco.value
    // CHECK: 'A'

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
