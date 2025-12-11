// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test eco.expect with i32 (Char) passthrough.
// Verifies unboxed char passthrough in expect operation.

module {
  func.func @main() -> i64 {
    %msg = eco.string_literal "should not see this" : !eco.value

    // Test with passing condition and i32 passthrough
    %char_A = arith.constant 65 : i32
    %cond_true = arith.constant true
    %result1 = eco.expect %cond_true, %msg, %char_A : i32 -> i32
    // Convert to i64 for dbg since direct i32 may show as char
    %as_i64 = arith.extsi %result1 : i32 to i64
    eco.dbg %as_i64 : i64
    // CHECK: 65

    // Test with different char
    %char_z = arith.constant 122 : i32
    %result2 = eco.expect %cond_true, %msg, %char_z : i32 -> i32
    %as_i64_2 = arith.extsi %result2 : i32 to i64
    eco.dbg %as_i64_2 : i64
    // CHECK: 122

    // Test with unicode char
    %char_alpha = arith.constant 945 : i32  // Greek alpha
    %result3 = eco.expect %cond_true, %msg, %char_alpha : i32 -> i32
    %as_i64_3 = arith.extsi %result3 : i32 to i64
    eco.dbg %as_i64_3 : i64
    // CHECK: 945

    // Test with zero (null char)
    %char_null = arith.constant 0 : i32
    %result4 = eco.expect %cond_true, %msg, %char_null : i32 -> i32
    %as_i64_4 = arith.extsi %result4 : i32 to i64
    eco.dbg %as_i64_4 : i64
    // CHECK: 0

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
