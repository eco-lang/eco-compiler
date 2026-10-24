// RUN: not %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test eco.crash with a constructed message value: ecoc prints the message
// and exits with status 1 (`not`).

module {
  func.func @main() {
    // Create an error message
    %msg = eco.string_literal "Intentional crash for testing" : !eco.value

    // Print something first to verify execution started
    %c42 = arith.constant 42 : i64
    eco.dbg %c42 : i64
    // CHECK: 42

    // Now crash - this terminates execution
    // CHECK: Elm runtime error: Intentional crash for testing
    eco.crash %msg : !eco.value
  }
}
