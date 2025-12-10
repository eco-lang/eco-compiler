// RUN: not %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test eco.expect when condition is false (should crash).

module {
  func.func @main() -> i64 {
    // Create error message
    %msg = eco.string_literal "assertion failed" : !eco.value

    // Create passthrough value
    %i42 = arith.constant 42 : i64
    %boxed = eco.box %i42 : i64 -> !eco.value

    // Condition is false, so expect should crash
    %false = arith.constant 0 : i1
    %result = eco.expect %false, %msg, %boxed : !eco.value -> !eco.value

    // This should not be reached
    eco.dbg %result : !eco.value

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
// CHECK: assertion failed
