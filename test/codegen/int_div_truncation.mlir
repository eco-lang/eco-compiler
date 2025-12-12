// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test eco.int.div truncation toward zero (C semantics).
// Unlike floored division, truncated division rounds toward zero.
// -7 / 3 = -2 (truncated), not -3 (floored)

module {
  func.func @main() -> i64 {
    // Positive / Positive: 7 / 3 = 2
    %c7 = arith.constant 7 : i64
    %c3 = arith.constant 3 : i64
    %div1 = eco.int.div %c7, %c3 : i64
    eco.dbg %div1 : i64
    // CHECK: [eco.dbg] 2

    // Negative / Positive: -7 / 3 = -2 (NOT -3)
    %cn7 = arith.constant -7 : i64
    %div2 = eco.int.div %cn7, %c3 : i64
    eco.dbg %div2 : i64
    // CHECK: [eco.dbg] -2

    // Positive / Negative: 7 / -3 = -2 (NOT -3)
    %cn3 = arith.constant -3 : i64
    %div3 = eco.int.div %c7, %cn3 : i64
    eco.dbg %div3 : i64
    // CHECK: [eco.dbg] -2

    // Negative / Negative: -7 / -3 = 2
    %div4 = eco.int.div %cn7, %cn3 : i64
    eco.dbg %div4 : i64
    // CHECK: [eco.dbg] 2

    // Exact division: 9 / 3 = 3
    %c9 = arith.constant 9 : i64
    %div5 = eco.int.div %c9, %c3 : i64
    eco.dbg %div5 : i64
    // CHECK: [eco.dbg] 3

    // Exact negative: -9 / 3 = -3
    %cn9 = arith.constant -9 : i64
    %div6 = eco.int.div %cn9, %c3 : i64
    eco.dbg %div6 : i64
    // CHECK: [eco.dbg] -3

    // Division by 1: 42 / 1 = 42
    %c42 = arith.constant 42 : i64
    %c1 = arith.constant 1 : i64
    %div7 = eco.int.div %c42, %c1 : i64
    eco.dbg %div7 : i64
    // CHECK: [eco.dbg] 42

    // Division by -1: 42 / -1 = -42
    %cn1 = arith.constant -1 : i64
    %div8 = eco.int.div %c42, %cn1 : i64
    eco.dbg %div8 : i64
    // CHECK: [eco.dbg] -42

    // Large values
    %big = arith.constant 1000000007 : i64
    %div9 = eco.int.div %big, %c3 : i64
    eco.dbg %div9 : i64
    // CHECK: [eco.dbg] 333333335

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
