// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test that box followed by unbox preserves the original value.

module {
  func.func @main() -> i64 {
    // Integer roundtrip
    %i1 = arith.constant 12345 : i64
    %boxed_i1 = eco.box %i1 : i64 -> !eco.value
    %unboxed_i1 = eco.unbox %boxed_i1 : !eco.value -> i64
    %boxed_again = eco.box %unboxed_i1 : i64 -> !eco.value
    eco.dbg %boxed_again : !eco.value
    // CHECK: 12345

    // Negative integer roundtrip
    %i2 = arith.constant -9999 : i64
    %boxed_i2 = eco.box %i2 : i64 -> !eco.value
    %unboxed_i2 = eco.unbox %boxed_i2 : !eco.value -> i64
    %boxed_i2_again = eco.box %unboxed_i2 : i64 -> !eco.value
    eco.dbg %boxed_i2_again : !eco.value
    // CHECK: -9999

    // Float roundtrip
    %f1 = arith.constant 3.14159 : f64
    %boxed_f1 = eco.box %f1 : f64 -> !eco.value
    %unboxed_f1 = eco.unbox %boxed_f1 : !eco.value -> f64
    %boxed_f1_again = eco.box %unboxed_f1 : f64 -> !eco.value
    eco.dbg %boxed_f1_again : !eco.value
    // CHECK: 3.14159

    // Character roundtrip
    %c1 = arith.constant 88 : i32  // 'X'
    %boxed_c1 = eco.box %c1 : i32 -> !eco.value
    %unboxed_c1 = eco.unbox %boxed_c1 : !eco.value -> i32
    %boxed_c1_again = eco.box %unboxed_c1 : i32 -> !eco.value
    eco.dbg %boxed_c1_again : !eco.value
    // CHECK: 'X'

    // Large integer roundtrip
    %i3 = arith.constant 9223372036854775807 : i64
    %boxed_i3 = eco.box %i3 : i64 -> !eco.value
    %unboxed_i3 = eco.unbox %boxed_i3 : !eco.value -> i64
    %boxed_i3_again = eco.box %unboxed_i3 : i64 -> !eco.value
    eco.dbg %boxed_i3_again : !eco.value
    // CHECK: 9223372036854775807

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
