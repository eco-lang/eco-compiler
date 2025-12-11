// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test eco.int.min and eco.int.max with INT64_MIN and INT64_MAX values.

module {
  func.func @main() -> i64 {
    %min_int = arith.constant -9223372036854775808 : i64
    %max_int = arith.constant 9223372036854775807 : i64
    %zero = arith.constant 0 : i64
    %one = arith.constant 1 : i64
    %neg_one = arith.constant -1 : i64

    // min(INT64_MIN, INT64_MAX) = INT64_MIN
    %r1 = eco.int.min %min_int, %max_int : i64
    eco.dbg %r1 : i64
    // CHECK: -9223372036854775808

    // max(INT64_MIN, INT64_MAX) = INT64_MAX
    %r2 = eco.int.max %min_int, %max_int : i64
    eco.dbg %r2 : i64
    // CHECK: 9223372036854775807

    // min(INT64_MIN, 0) = INT64_MIN
    %r3 = eco.int.min %min_int, %zero : i64
    eco.dbg %r3 : i64
    // CHECK: -9223372036854775808

    // max(INT64_MIN, 0) = 0
    %r4 = eco.int.max %min_int, %zero : i64
    eco.dbg %r4 : i64
    // CHECK: 0

    // min(INT64_MAX, 0) = 0
    %r5 = eco.int.min %max_int, %zero : i64
    eco.dbg %r5 : i64
    // CHECK: 0

    // max(INT64_MAX, 0) = INT64_MAX
    %r6 = eco.int.max %max_int, %zero : i64
    eco.dbg %r6 : i64
    // CHECK: 9223372036854775807

    // min(INT64_MIN, INT64_MIN) = INT64_MIN (same values)
    %r7 = eco.int.min %min_int, %min_int : i64
    eco.dbg %r7 : i64
    // CHECK: -9223372036854775808

    // max(INT64_MAX, INT64_MAX) = INT64_MAX (same values)
    %r8 = eco.int.max %max_int, %max_int : i64
    eco.dbg %r8 : i64
    // CHECK: 9223372036854775807

    // min(INT64_MIN, -1) = INT64_MIN
    %r9 = eco.int.min %min_int, %neg_one : i64
    eco.dbg %r9 : i64
    // CHECK: -9223372036854775808

    // max(INT64_MAX, 1) = INT64_MAX
    %r10 = eco.int.max %max_int, %one : i64
    eco.dbg %r10 : i64
    // CHECK: 9223372036854775807

    // Commutative tests
    // min(INT64_MAX, INT64_MIN) = INT64_MIN
    %r11 = eco.int.min %max_int, %min_int : i64
    eco.dbg %r11 : i64
    // CHECK: -9223372036854775808

    // max(INT64_MAX, INT64_MIN) = INT64_MAX
    %r12 = eco.int.max %max_int, %min_int : i64
    eco.dbg %r12 : i64
    // CHECK: 9223372036854775807

    %ret = arith.constant 0 : i64
    return %ret : i64
  }
}
