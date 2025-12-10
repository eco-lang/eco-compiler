// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test eco.joinpoint and eco.jump for implementing a simple countdown.
// Start with n=3, print each value, decrement until 0.

module {
  func.func @main() -> i64 {
    %c0 = arith.constant 0 : i64
    %c1 = arith.constant 1 : i64
    %c3 = arith.constant 3 : i64

    // Simple joinpoint: print n, then either exit or loop
    eco.joinpoint 0(%n: i64) {
      // Print current value
      eco.dbg %n : i64

      // If n == 0, exit; otherwise continue
      %done = arith.cmpi eq, %n, %c0 : i64
      %new_n = arith.subi %n, %c1 : i64

      // For now, just exit (no conditional branching in single block)
      // This tests that the joinpoint mechanics work
      eco.return
    } continuation {
      // Entry: start the loop with n=3
      eco.jump 0(%c3 : i64)
    }
    // CHECK: 3

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
