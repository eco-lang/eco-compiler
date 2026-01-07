// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// This test verifies that embedded constants (Nil, True, False, etc.) are always
// lowered as BOXED HPointers, not as unboxed primitives.
//
// Key invariant: eco.constant produces !eco.value type, which must always be
// stored using eco_store_field (boxed path), never eco_store_field_i64.
//
// The verifier now enforces that unboxed_bitmap bits can only be set for
// fields with primitive types (i64, f64, i32), not for !eco.value.

module {
  func.func @main() -> i64 {
    // === Test all constant types are stored and retrieved correctly ===
    %nil = eco.constant Nil : !eco.value
    %true = eco.constant True : !eco.value
    %false = eco.constant False : !eco.value
    %unit = eco.constant Unit : !eco.value
    %nothing = eco.constant Nothing : !eco.value
    %empty_str = eco.constant EmptyString : !eco.value
    %empty_rec = eco.constant EmptyRec : !eco.value

    // Store each constant in a structure field and project back
    // All fields are !eco.value, so no unboxed_bitmap needed (defaults to 0)
    %s1 = eco.construct.custom(%nil) {tag = 1 : i64, size = 1 : i64} : (!eco.value) -> !eco.value
    %p1 = eco.project.custom %s1[0] : !eco.value -> !eco.value
    eco.dbg %p1 : !eco.value
    // CHECK: []

    %s2 = eco.construct.custom(%true) {tag = 2 : i64, size = 1 : i64} : (!eco.value) -> !eco.value
    %p2 = eco.project.custom %s2[0] : !eco.value -> !eco.value
    eco.dbg %p2 : !eco.value
    // CHECK: True

    %s3 = eco.construct.custom(%false) {tag = 3 : i64, size = 1 : i64} : (!eco.value) -> !eco.value
    %p3 = eco.project.custom %s3[0] : !eco.value -> !eco.value
    eco.dbg %p3 : !eco.value
    // CHECK: False

    %s4 = eco.construct.custom(%unit) {tag = 4 : i64, size = 1 : i64} : (!eco.value) -> !eco.value
    %p4 = eco.project.custom %s4[0] : !eco.value -> !eco.value
    eco.dbg %p4 : !eco.value
    // CHECK: ()

    %s5 = eco.construct.custom(%nothing) {tag = 5 : i64, size = 1 : i64} : (!eco.value) -> !eco.value
    %p5 = eco.project.custom %s5[0] : !eco.value -> !eco.value
    eco.dbg %p5 : !eco.value
    // CHECK: Nothing

    %s6 = eco.construct.custom(%empty_str) {tag = 6 : i64, size = 1 : i64} : (!eco.value) -> !eco.value
    %p6 = eco.project.custom %s6[0] : !eco.value -> !eco.value
    eco.dbg %p6 : !eco.value
    // CHECK: ""

    %s7 = eco.construct.custom(%empty_rec) {tag = 7 : i64, size = 1 : i64} : (!eco.value) -> !eco.value
    %p7 = eco.project.custom %s7[0] : !eco.value -> !eco.value
    eco.dbg %p7 : !eco.value
    // CHECK: {}

    // === Test constants mixed with boxed values ===
    %i42 = arith.constant 42 : i64
    %b42 = eco.box %i42 : i64 -> !eco.value

    // Both are !eco.value (boxed), unboxed_bitmap = 0
    %mix1 = eco.construct.custom(%b42, %nil) {tag = 10 : i64, size = 2 : i64, unboxed_bitmap = 0 : i64} : (!eco.value, !eco.value) -> !eco.value
    eco.dbg %mix1 : !eco.value
    // CHECK: Ctor10 42 []

    %mix1_p0 = eco.project.custom %mix1[0] : !eco.value -> !eco.value
    eco.dbg %mix1_p0 : !eco.value
    // CHECK: 42

    %mix1_p1 = eco.project.custom %mix1[1] : !eco.value -> !eco.value
    eco.dbg %mix1_p1 : !eco.value
    // CHECK: []

    // === Test constants mixed with unboxed primitives ===
    // Here we have: i64 (unboxed), !eco.value (constant, boxed)
    // unboxed_bitmap = 1 (only field 0 is unboxed)
    %raw42 = arith.constant 42 : i64
    %mix2 = eco.construct.custom(%raw42, %true) {tag = 11 : i64, size = 2 : i64, unboxed_bitmap = 1 : i64} : (i64, !eco.value) -> !eco.value
    eco.dbg %mix2 : !eco.value
    // CHECK: Ctor11 42 True

    %mix2_p0 = eco.project.custom %mix2[0] : !eco.value -> i64
    eco.dbg %mix2_p0 : i64
    // CHECK: 42

    %mix2_p1 = eco.project.custom %mix2[1] : !eco.value -> !eco.value
    eco.dbg %mix2_p1 : !eco.value
    // CHECK: True

    // === Test constant at end of structure with multiple unboxed fields ===
    // i64, f64, !eco.value - unboxed_bitmap = 3 (fields 0 and 1 are unboxed)
    %pi = arith.constant 3.14159 : f64
    %mix3 = eco.construct.custom(%raw42, %pi, %false) {tag = 12 : i64, size = 3 : i64, unboxed_bitmap = 3 : i64} : (i64, f64, !eco.value) -> !eco.value
    eco.dbg %mix3 : !eco.value
    // CHECK: Ctor12

    %mix3_p2 = eco.project.custom %mix3[2] : !eco.value -> !eco.value
    eco.dbg %mix3_p2 : !eco.value
    // CHECK: False

    // === Test constant in middle of structure ===
    // i64, !eco.value, i64 - unboxed_bitmap = 5 (0b101, fields 0 and 2 are unboxed)
    %i99 = arith.constant 99 : i64
    %mix4 = eco.construct.custom(%raw42, %nil, %i99) {tag = 13 : i64, size = 3 : i64, unboxed_bitmap = 5 : i64} : (i64, !eco.value, i64) -> !eco.value
    eco.dbg %mix4 : !eco.value
    // CHECK: Ctor13 42 [] 99

    %mix4_p1 = eco.project.custom %mix4[1] : !eco.value -> !eco.value
    eco.dbg %mix4_p1 : !eco.value
    // CHECK: []

    // === Test Cons cells with constant Nil tail ===
    // This is the most common pattern - lists ending with Nil
    // head (!eco.value), tail (!eco.value = Nil) - both boxed
    %list1 = eco.construct.custom(%b42, %nil) {tag = 0 : i64, size = 2 : i64, unboxed_bitmap = 0 : i64} : (!eco.value, !eco.value) -> !eco.value
    eco.dbg %list1 : !eco.value
    // CHECK: [42]

    // Longer list: [1, 2, Nil]
    %i1 = arith.constant 1 : i64
    %i2 = arith.constant 2 : i64
    %b1 = eco.box %i1 : i64 -> !eco.value
    %b2 = eco.box %i2 : i64 -> !eco.value
    %l2 = eco.construct.custom(%b2, %nil) {tag = 0 : i64, size = 2 : i64, unboxed_bitmap = 0 : i64} : (!eco.value, !eco.value) -> !eco.value
    %l1 = eco.construct.custom(%b1, %l2) {tag = 0 : i64, size = 2 : i64, unboxed_bitmap = 0 : i64} : (!eco.value, !eco.value) -> !eco.value
    eco.dbg %l1 : !eco.value
    // CHECK: [1, 2]

    // === Test structure containing only constants ===
    %all_consts = eco.construct.custom(%nil, %true, %false) {tag = 20 : i64, size = 3 : i64} : (!eco.value, !eco.value, !eco.value) -> !eco.value
    eco.dbg %all_consts : !eco.value
    // CHECK: Ctor20 [] True False

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
