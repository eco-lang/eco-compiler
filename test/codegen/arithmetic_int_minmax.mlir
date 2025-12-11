// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test MIN_INT edge cases for various integer operations.
// MIN_INT = -9223372036854775808 (-2^63)

module {
  func.func @main() -> i64 {
    %max_int = arith.constant 9223372036854775807 : i64
    %min_int = arith.constant -9223372036854775808 : i64
    %neg1 = arith.constant -1 : i64
    %c0 = arith.constant 0 : i64
    %c1 = arith.constant 1 : i64

    // abs(MIN_INT) overflows - in two's complement, this wraps to MIN_INT
    // This is undefined behavior in C, but we test what actually happens
    %abs_min = eco.int.abs %min_int : i64
    eco.dbg %abs_min : i64
    // CHECK: -9223372036854775808

    // abs(MAX_INT) should be MAX_INT
    %abs_max = eco.int.abs %max_int : i64
    eco.dbg %abs_max : i64
    // CHECK: 9223372036854775807

    // negate(MIN_INT) overflows - wraps to MIN_INT
    %neg_min = eco.int.negate %min_int : i64
    eco.dbg %neg_min : i64
    // CHECK: -9223372036854775808

    // negate(MAX_INT) should be -MAX_INT = MIN_INT + 1
    %neg_max = eco.int.negate %max_int : i64
    eco.dbg %neg_max : i64
    // CHECK: -9223372036854775807

    // MIN_INT / -1 would overflow in two's complement
    // Result depends on implementation
    %div_min = eco.int.div %min_int, %neg1 : i64
    eco.dbg %div_min : i64
    // CHECK: -9223372036854775808

    // MIN_INT / 1 = MIN_INT
    %div_min_1 = eco.int.div %min_int, %c1 : i64
    eco.dbg %div_min_1 : i64
    // CHECK: -9223372036854775808

    // MIN_INT modBy 1 should be 0
    %mod_min = eco.int.modby %c1, %min_int : i64
    eco.dbg %mod_min : i64
    // CHECK: 0

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
