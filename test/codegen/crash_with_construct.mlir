// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
// XFAIL: *
//
// Test eco.crash with a constructed message value.
// This test is expected to crash, so marked XFAIL.

module {
  func.func @main() {
    // Create an error message
    %msg = eco.string_literal "Intentional crash for testing" : !eco.value

    // Print something first to verify execution started
    %c42 = arith.constant 42 : i64
    eco.dbg %c42 : i64
    // CHECK: 42

    // Now crash - this terminates execution
    eco.crash %msg : !eco.value
  }
}
