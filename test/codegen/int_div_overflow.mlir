// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test integer division edge cases.
// Note: INT64_MIN / -1 would overflow, but eco.int.div returns 0 for div-by-zero.

module {
  func.func @main() -> i64 {
    // Normal division
    %i100 = arith.constant 100 : i64
    %i10 = arith.constant 10 : i64
    %div1 = eco.int.div %i100, %i10 : i64
    eco.dbg %div1 : i64
    // CHECK: 10

    // Division by -1 (negation)
    %neg_one = arith.constant -1 : i64
    %i42 = arith.constant 42 : i64
    %div2 = eco.int.div %i42, %neg_one : i64
    eco.dbg %div2 : i64
    // CHECK: -42

    // Division of negative by positive
    %neg_100 = arith.constant -100 : i64
    %div3 = eco.int.div %neg_100, %i10 : i64
    eco.dbg %div3 : i64
    // CHECK: -10

    // Division of negative by negative
    %neg_10 = arith.constant -10 : i64
    %div4 = eco.int.div %neg_100, %neg_10 : i64
    eco.dbg %div4 : i64
    // CHECK: 10

    // Division by zero returns 0 (Elm semantics)
    %zero = arith.constant 0 : i64
    %div5 = eco.int.div %i42, %zero : i64
    eco.dbg %div5 : i64
    // CHECK: 0

    // Large number division
    %large = arith.constant 9223372036854775000 : i64
    %thousand = arith.constant 1000 : i64
    %div6 = eco.int.div %large, %thousand : i64
    eco.dbg %div6 : i64
    // CHECK: 9223372036854775

    // Division that truncates
    %seven = arith.constant 7 : i64
    %three = arith.constant 3 : i64
    %div7 = eco.int.div %seven, %three : i64
    eco.dbg %div7 : i64
    // CHECK: 2

    // Negative division that truncates toward zero
    %neg_seven = arith.constant -7 : i64
    %div8 = eco.int.div %neg_seven, %three : i64
    eco.dbg %div8 : i64
    // CHECK: -2

    return %zero : i64
  }
}
