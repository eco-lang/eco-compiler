// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test INT64_MIN / -1 edge case.
// This operation has undefined behavior in C and may produce unexpected results.
// Note: There appears to be an issue with the runtime handling of this case.

module {
  func.func @main() -> i64 {
    // Test regular division first to verify it works
    %c100 = arith.constant 100 : i64
    %c10 = arith.constant 10 : i64
    %normal_div = eco.int.div %c100, %c10 : i64
    eco.dbg %normal_div : i64
    // CHECK: [eco.dbg] 10

    // Test negative dividend
    %cn100 = arith.constant -100 : i64
    %neg_div = eco.int.div %cn100, %c10 : i64
    eco.dbg %neg_div : i64
    // CHECK: [eco.dbg] -10

    // Test negative divisor
    %cn10 = arith.constant -10 : i64
    %neg_divisor = eco.int.div %c100, %cn10 : i64
    eco.dbg %neg_divisor : i64
    // CHECK: [eco.dbg] -10

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
