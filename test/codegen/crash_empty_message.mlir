// RUN: not %ecoc %s -emit=jit 2>&1 | %FileCheck %s
// XFAIL: *
//
// Test eco.crash with an empty string message.
// Currently crashes without printing the error message prefix.
// TODO: Fix eco_crash to handle empty strings gracefully.

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
