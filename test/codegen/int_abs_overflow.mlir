// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test eco.int.abs including edge cases.
// abs(INT64_MIN) wraps to INT64_MIN (overflow).

module {
  func.func @main() -> i64 {
    // Normal abs of positive
    %i42 = arith.constant 42 : i64
    %abs42 = eco.int.abs %i42 : i64
    eco.dbg %abs42 : i64
    // CHECK: 42

    // Normal abs of negative
    %neg100 = arith.constant -100 : i64
    %abs100 = eco.int.abs %neg100 : i64
    eco.dbg %abs100 : i64
    // CHECK: 100

    // abs of zero
    %zero = arith.constant 0 : i64
    %abs_zero = eco.int.abs %zero : i64
    eco.dbg %abs_zero : i64
    // CHECK: 0

    // abs of -1
    %neg_one = arith.constant -1 : i64
    %abs_one = eco.int.abs %neg_one : i64
    eco.dbg %abs_one : i64
    // CHECK: 1

    // Large negative
    %neg_large = arith.constant -9223372036854775000 : i64
    %abs_large = eco.int.abs %neg_large : i64
    eco.dbg %abs_large : i64
    // CHECK: 9223372036854775000

    // INT64_MAX
    %int_max = arith.constant 9223372036854775807 : i64
    %abs_max = eco.int.abs %int_max : i64
    eco.dbg %abs_max : i64
    // CHECK: 9223372036854775807

    // INT64_MIN = -9223372036854775808
    // abs() tries to negate, which wraps to itself
    %int_min = arith.constant -9223372036854775808 : i64
    %abs_min = eco.int.abs %int_min : i64
    // This wraps around to INT64_MIN due to overflow
    eco.dbg %abs_min : i64
    // CHECK: -9223372036854775808

    return %zero : i64
  }
}
