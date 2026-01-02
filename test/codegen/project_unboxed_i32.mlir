// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test eco.project extracting unboxed i16 (Char) field.
// Tests i16 field extraction and potential sign extension issues.

module {
  func.func @main() -> i64 {
    // Create characters
    %char_A = arith.constant 65 : i16   // 'A'
    %char_z = arith.constant 122 : i16  // 'z'
    %char_emoji = arith.constant 9786 : i16  // U+263A white smiling face (BMP)

    // Construct with unboxed i16 fields
    // bitmap bit 0 and 1 set for i16 fields
    %ctor = eco.construct(%char_A, %char_z) {tag = 0 : i64, size = 2 : i64, unboxed_bitmap = 3 : i64} : (i16, i16) -> !eco.value

    eco.dbg %ctor : !eco.value
    // CHECK: [eco.dbg] Ctor0 65 122

    // Project char fields
    %p0 = eco.project %ctor[0] : !eco.value -> i16
    eco.dbg %p0 : i16
    // CHECK: [eco.dbg] 'A'

    %p1 = eco.project %ctor[1] : !eco.value -> i16
    eco.dbg %p1 : i16
    // CHECK: [eco.dbg] 'z'

    // Test with BMP Unicode codepoint
    %ctor2 = eco.construct(%char_emoji) {tag = 1 : i64, size = 1 : i64, unboxed_bitmap = 1 : i64} : (i16) -> !eco.value
    %p2 = eco.project %ctor2[0] : !eco.value -> i16
    eco.dbg %p2 : i16
    // CHECK: [eco.dbg] '\u263A'

    // Mix boxed eco.value and unboxed i16
    %boxed = eco.box %char_A : i16 -> !eco.value
    %ctor3 = eco.construct(%boxed, %char_z) {tag = 2 : i64, size = 2 : i64, unboxed_bitmap = 2 : i64} : (!eco.value, i16) -> !eco.value

    %p3_boxed = eco.project %ctor3[0] : !eco.value -> !eco.value
    eco.dbg %p3_boxed : !eco.value
    // CHECK: [eco.dbg] 'A'

    %p3_unboxed = eco.project %ctor3[1] : !eco.value -> i16
    eco.dbg %p3_unboxed : i16
    // CHECK: [eco.dbg] 'z'

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
