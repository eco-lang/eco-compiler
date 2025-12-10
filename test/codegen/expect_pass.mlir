// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test eco.expect when condition is true (passthrough succeeds).

module {
  func.func @main() -> i64 {
    // Create a message string (won't be used if condition is true)
    %msg = eco.string_literal "should not crash" : !eco.value

    // Create passthrough value
    %i42 = arith.constant 42 : i64
    %boxed = eco.box %i42 : i64 -> !eco.value

    // Condition is true, so expect passes through
    %true = arith.constant 1 : i1
    %result = eco.expect %true, %msg, %boxed : !eco.value -> !eco.value

    // Unbox and print
    %unboxed = eco.unbox %result : !eco.value -> i64
    eco.dbg %unboxed : i64
    // CHECK: 42

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
