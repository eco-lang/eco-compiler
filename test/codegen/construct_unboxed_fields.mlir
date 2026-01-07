// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test eco.construct with unboxed fields in various structure types.
// Tests Cons (list cells), and Custom ADTs with unboxed integer, float, and char fields.

module {
  func.func @main() -> i64 {
    %nil = eco.constant Nil : !eco.value

    // === Cons with unboxed integer head ===
    // unboxed_bitmap = 1 means field 0 (head) is unboxed
    // tag = 0 (ctor tag) with size = 2 is treated as a list Cons cell
    %i42 = arith.constant 42 : i64
    %cons_int = eco.construct.custom(%i42, %nil) {tag = 0 : i64, size = 2 : i64, unboxed_bitmap = 1 : i64} : (i64, !eco.value) -> !eco.value
    eco.dbg %cons_int : !eco.value
    // CHECK: [42]

    // === List with multiple unboxed integers ===
    %i1 = arith.constant 1 : i64
    %i2 = arith.constant 2 : i64
    %i3 = arith.constant 3 : i64
    %l3 = eco.construct.custom(%i3, %nil) {tag = 0 : i64, size = 2 : i64, unboxed_bitmap = 1 : i64} : (i64, !eco.value) -> !eco.value
    %l2 = eco.construct.custom(%i2, %l3) {tag = 0 : i64, size = 2 : i64, unboxed_bitmap = 1 : i64} : (i64, !eco.value) -> !eco.value
    %list_ints = eco.construct.custom(%i1, %l2) {tag = 0 : i64, size = 2 : i64, unboxed_bitmap = 1 : i64} : (i64, !eco.value) -> !eco.value
    eco.dbg %list_ints : !eco.value
    // CHECK: [1, 2, 3]

    // === Custom ADT with two unboxed integers (NOT a list) ===
    // Use ctor tag = 10 (not 0) so it's not treated as a Cons cell
    // unboxed_bitmap = 3 (0b11) means both fields are unboxed
    %i10 = arith.constant 10 : i64
    %i20 = arith.constant 20 : i64
    %pair_ints = eco.construct.custom(%i10, %i20) {tag = 10 : i64, size = 2 : i64, unboxed_bitmap = 3 : i64} : (i64, i64) -> !eco.value
    eco.dbg %pair_ints : !eco.value
    // CHECK: Ctor10 10 20

    // Project unboxed fields
    %first = eco.project.custom %pair_ints[0] : !eco.value -> i64
    eco.dbg %first : i64
    // CHECK: 10

    %second = eco.project.custom %pair_ints[1] : !eco.value -> i64
    eco.dbg %second : i64
    // CHECK: 20

    // === Custom with three unboxed integers ===
    // unboxed_bitmap = 7 (0b111) means all three fields are unboxed
    %i100 = arith.constant 100 : i64
    %i200 = arith.constant 200 : i64
    %i300 = arith.constant 300 : i64
    %triple_ints = eco.construct.custom(%i100, %i200, %i300) {tag = 11 : i64, size = 3 : i64, unboxed_bitmap = 7 : i64} : (i64, i64, i64) -> !eco.value
    eco.dbg %triple_ints : !eco.value
    // CHECK: Ctor11 100 200 300

    // Project middle unboxed field
    %middle = eco.project.custom %triple_ints[1] : !eco.value -> i64
    eco.dbg %middle : i64
    // CHECK: 200

    // === Mixed: first field boxed, second unboxed ===
    // unboxed_bitmap = 2 (0b10) means field 1 is unboxed
    %b42 = eco.box %i42 : i64 -> !eco.value
    %i99 = arith.constant 99 : i64
    %mixed = eco.construct.custom(%b42, %i99) {tag = 5 : i64, size = 2 : i64, unboxed_bitmap = 2 : i64} : (!eco.value, i64) -> !eco.value
    eco.dbg %mixed : !eco.value
    // CHECK: Ctor5 42 99

    // Project the unboxed field
    %unboxed_field = eco.project.custom %mixed[1] : !eco.value -> i64
    eco.dbg %unboxed_field : i64
    // CHECK: 99

    // === Custom with unboxed floats ===
    // Note: print_custom doesn't know field types, so unboxed floats print as raw bits
    // The eco.project verifies the values are stored correctly
    %f1 = arith.constant 3.14 : f64
    %f2 = arith.constant 2.718 : f64
    %pair_floats = eco.construct.custom(%f1, %f2) {tag = 1 : i64, size = 2 : i64, unboxed_bitmap = 3 : i64} : (f64, f64) -> !eco.value
    eco.dbg %pair_floats : !eco.value
    // CHECK: Ctor1 4614253070214989087 4613302810693613912

    // Project unboxed float
    %float_field = eco.project.custom %pair_floats[0] : !eco.value -> f64
    eco.dbg %float_field : f64
    // CHECK: 3.14

    // === Custom with unboxed char ===
    // Note: print_custom doesn't know field types, so chars print as integers
    // The eco.project verifies the values are stored correctly
    %cA = arith.constant 65 : i16
    %cB = arith.constant 66 : i16
    %pair_chars = eco.construct.custom(%cA, %cB) {tag = 2 : i64, size = 2 : i64, unboxed_bitmap = 3 : i64} : (i16, i16) -> !eco.value
    eco.dbg %pair_chars : !eco.value
    // CHECK: Ctor2 65 66

    // Project unboxed char
    %char_field = eco.project.custom %pair_chars[0] : !eco.value -> i16
    eco.dbg %char_field : i16
    // CHECK: 'A'

    // === Negative integer in unboxed field (in list) ===
    %ineg = arith.constant -42 : i64
    %cons_neg = eco.construct.custom(%ineg, %nil) {tag = 0 : i64, size = 2 : i64, unboxed_bitmap = 1 : i64} : (i64, !eco.value) -> !eco.value
    eco.dbg %cons_neg : !eco.value
    // CHECK: [-42]

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
