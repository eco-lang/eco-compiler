// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test alternating i64, f64, i32, !eco.value fields.
// Tests mixed unboxed handling with different types.

module {
  func.func @main() -> i64 {
    // Create values of different types
    %int_val = arith.constant 42 : i64
    %float_val = arith.constant 3.14 : f64
    %char_val = arith.constant 65 : i16  // 'A'
    %boxed_val = eco.box %int_val : i64 -> !eco.value

    // Construct with alternating types:
    // field 0: i64 (unboxed)
    // field 1: f64 (unboxed)
    // field 2: i16 (unboxed)
    // field 3: !eco.value (boxed)
    // unboxed_bitmap = 0b0111 = 7 (bits 0, 1, 2 set)
    %ctor = eco.construct.custom(%int_val, %float_val, %char_val, %boxed_val) {tag = 0 : i64, size = 4 : i64, unboxed_bitmap = 7 : i64} : (i64, f64, i16, !eco.value) -> !eco.value

    // Project and print each field
    %p0 = eco.project.custom %ctor[0] : !eco.value -> i64
    eco.dbg %p0 : i64
    // CHECK: [eco.dbg] 42

    %p1 = eco.project.custom %ctor[1] : !eco.value -> f64
    eco.dbg %p1 : f64
    // CHECK: [eco.dbg] 3.14

    %p2 = eco.project.custom %ctor[2] : !eco.value -> i16
    eco.dbg %p2 : i16
    // CHECK: [eco.dbg] 'A'

    %p3 = eco.project.custom %ctor[3] : !eco.value -> !eco.value
    %v3 = eco.unbox %p3 : !eco.value -> i64
    eco.dbg %v3 : i64
    // CHECK: [eco.dbg] 42

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
