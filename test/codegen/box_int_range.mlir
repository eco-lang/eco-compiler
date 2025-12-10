// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test integer boxing with various edge cases.

module {
  func.func @main() -> i64 {
    // Zero
    %i0 = arith.constant 0 : i64
    %b0 = eco.box %i0 : i64 -> !eco.value
    eco.dbg %b0 : !eco.value
    // CHECK: 0

    // Positive integer
    %i1 = arith.constant 42 : i64
    %b1 = eco.box %i1 : i64 -> !eco.value
    eco.dbg %b1 : !eco.value
    // CHECK: 42

    // Negative integer
    %i2 = arith.constant -123 : i64
    %b2 = eco.box %i2 : i64 -> !eco.value
    eco.dbg %b2 : !eco.value
    // CHECK: -123

    // Large positive (fits in 32 bits)
    %i3 = arith.constant 2147483647 : i64
    %b3 = eco.box %i3 : i64 -> !eco.value
    eco.dbg %b3 : !eco.value
    // CHECK: 2147483647

    // Large negative (fits in 32 bits)
    %i4 = arith.constant -2147483648 : i64
    %b4 = eco.box %i4 : i64 -> !eco.value
    eco.dbg %b4 : !eco.value
    // CHECK: -2147483648

    // Very large positive (needs 64 bits)
    %i5 = arith.constant 9223372036854775807 : i64
    %b5 = eco.box %i5 : i64 -> !eco.value
    eco.dbg %b5 : !eco.value
    // CHECK: 9223372036854775807

    // Very large negative (INT64_MIN)
    %i6 = arith.constant -9223372036854775808 : i64
    %b6 = eco.box %i6 : i64 -> !eco.value
    eco.dbg %b6 : !eco.value
    // CHECK: -9223372036854775808

    // Power of 2
    %i7 = arith.constant 1099511627776 : i64
    %b7 = eco.box %i7 : i64 -> !eco.value
    eco.dbg %b7 : !eco.value
    // CHECK: 1099511627776

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
