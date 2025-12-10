// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test eco.crash operation - unconditional panic with message.

module {
  func.func @main() -> i64 {
    // Print something first to verify we reach this point
    %i1 = arith.constant 1 : i64
    eco.dbg %i1 : i64
    // CHECK: 1

    // Create an error message
    %msg = eco.string_literal "Test crash message" : !eco.value

    // This should crash and print the message
    // CHECK: Elm runtime error: Test crash message
    eco.crash %msg : !eco.value
  }
}
