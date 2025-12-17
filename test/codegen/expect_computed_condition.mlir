// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test eco.expect with conditions computed from comparisons.
// Tests expect with dynamically computed boolean conditions.

module {
  func.func @main() -> i64 {
    %msg = eco.string_literal "comparison failed" : !eco.value

    // Test with integer comparison - true case
    %i10 = arith.constant 10 : i64
    %i5 = arith.constant 5 : i64
    %b10 = eco.box %i10 : i64 -> !eco.value
    %b5 = eco.box %i5 : i64 -> !eco.value

    %cmp_gt = eco.int.gt %i10, %i5 : i64
    %result1 = eco.expect %cmp_gt, %msg, %b10 : !eco.value -> !eco.value
    eco.dbg %result1 : !eco.value
    // CHECK: [eco.dbg] 10

    // Test with equality - true case
    %i42 = arith.constant 42 : i64
    %i42_copy = arith.constant 42 : i64
    %b42 = eco.box %i42 : i64 -> !eco.value

    %cmp_eq = eco.int.eq %i42, %i42_copy : i64
    %result2 = eco.expect %cmp_eq, %msg, %b42 : !eco.value -> !eco.value
    eco.dbg %result2 : !eco.value
    // CHECK: [eco.dbg] 42

    // Test with less-than - true case
    %cmp_lt = eco.int.lt %i5, %i10 : i64
    %result3 = eco.expect %cmp_lt, %msg, %b5 : !eco.value -> !eco.value
    eco.dbg %result3 : !eco.value
    // CHECK: [eco.dbg] 5

    // Test with not-equal - true case
    %cmp_ne = eco.int.ne %i5, %i10 : i64
    %result4 = eco.expect %cmp_ne, %msg, %b5 : !eco.value -> !eco.value
    eco.dbg %result4 : !eco.value
    // CHECK: [eco.dbg] 5

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
