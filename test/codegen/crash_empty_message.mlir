// RUN: not %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test eco.crash with an empty string message: the empty string is an
// embedded constant with no heap object, and eco_crash still prints the
// error prefix before exiting with status 1.

module {
  func.func @main() -> i64 {
    // Print something to verify execution reaches this point
    %i1 = arith.constant 1 : i64
    eco.dbg %i1 : i64
    // CHECK: [eco.dbg] 1

    // Crash with empty message
    %empty = eco.string_literal "" : !eco.value
    // CHECK: Elm runtime error:
    eco.crash %empty : !eco.value
  }
}
