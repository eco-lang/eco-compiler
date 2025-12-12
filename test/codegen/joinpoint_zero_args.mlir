// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test joinpoint with minimal argument (single unused i64).
// Tests block argument handling edge case.

module {
  func.func @main() -> i64 {
    %c10 = arith.constant 10 : i64
    %c42 = arith.constant 42 : i64
    %c0 = arith.constant 0 : i64

    // Joinpoint with single unused argument (minimal case)
    eco.joinpoint 0(%unused: i64) {
      eco.dbg %c10 : i64
      eco.return
    } continuation {
      eco.jump 0(%c0 : i64)
    }
    // CHECK: [eco.dbg] 10

    // Another single-arg joinpoint
    eco.joinpoint 1(%unused2: i64) {
      eco.dbg %c42 : i64
      eco.return
    } continuation {
      eco.jump 1(%c0 : i64)
    }
    // CHECK: [eco.dbg] 42

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
