// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test eco.project extracting unboxed i32 (Char) fields. Char is a Unicode
// code point held in i32 (slot kind 3, the heap word holds it zero-extended
// to 64 bits); i32 here is Char, not some other 32-bit integer. Covers ASCII,
// BMP and astral code points (no truncation, no sign-extension issues).

module {
  func.func @main() -> i64 {
    // Create characters
    %char_A = arith.constant 65 : i32   // 'A'
    %char_z = arith.constant 122 : i32  // 'z'
    %char_emoji = arith.constant 9786 : i32  // U+263A white smiling face (BMP)

    // Construct with unboxed i32 fields
    // bitmap bit 0 and 1 set for i32 fields
    %ctor = eco.construct.custom(%char_A, %char_z) {tag = 0 : i64, size = 2 : i64, slot_kinds = array<i8: 3, 3>} : (i32, i32) -> !eco.value

    eco.dbg %ctor : !eco.value
    // CHECK: [eco.dbg] Ctor0 'A' 'z'

    // Project char fields
    %p0 = eco.project.custom %ctor[0] : !eco.value -> i32
    eco.dbg %p0 : i32
    // CHECK: [eco.dbg] 'A'

    %p1 = eco.project.custom %ctor[1] : !eco.value -> i32
    eco.dbg %p1 : i32
    // CHECK: [eco.dbg] 'z'

    // Test with a BMP Unicode code point (prints as UTF-8)
    %ctor2 = eco.construct.custom(%char_emoji) {tag = 1 : i64, size = 1 : i64, slot_kinds = array<i8: 3>} : (i32) -> !eco.value
    %p2 = eco.project.custom %ctor2[0] : !eco.value -> i32
    eco.dbg %p2 : i32
    // CHECK: [eco.dbg] '☺'

    // Mix boxed eco.value and unboxed i32
    %boxed = eco.box %char_A : i32 -> !eco.value
    %ctor3 = eco.construct.custom(%boxed, %char_z) {tag = 2 : i64, size = 2 : i64, slot_kinds = array<i8: 0, 3>} : (!eco.value, i32) -> !eco.value

    %p3_boxed = eco.project.custom %ctor3[0] : !eco.value -> !eco.value
    eco.dbg %p3_boxed : !eco.value
    // CHECK: [eco.dbg] 'A'

    %p3_unboxed = eco.project.custom %ctor3[1] : !eco.value -> i32
    eco.dbg %p3_unboxed : i32
    // CHECK: [eco.dbg] 'z'

    // Astral code point U+1F600 in a Char field: the full i32 survives the
    // heap word and the projection
    %char_astral = arith.constant 128512 : i32
    %ctor4 = eco.construct.custom(%char_astral, %char_A) {tag = 3 : i64, size = 2 : i64, slot_kinds = array<i8: 3, 3>} : (i32, i32) -> !eco.value
    eco.dbg %ctor4 : !eco.value
    // CHECK: [eco.dbg] Ctor3 '😀' 'A'
    %p4 = eco.project.custom %ctor4[0] : !eco.value -> i32
    %p4_code = eco.char.toInt %p4 : i32 -> i64
    eco.dbg %p4_code : i64
    // CHECK: [eco.dbg] 128512

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
