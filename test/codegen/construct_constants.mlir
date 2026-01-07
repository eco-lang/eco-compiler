// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test embedded constants (Nil, True, False, Unit, etc.) stored in structure fields.
// Constants MUST be marked as boxed (unboxed_bitmap bit = 0) because they use
// the HPointer encoding (bits 40-43), not raw primitive values.
//
// The ConstructOp verifier now enforces this rule:
//   - Fields with type !eco.value (including constants) must have unboxed_bitmap bit = 0
//   - Only primitive types (i64, f64, i32) may have unboxed_bitmap bit = 1
//
// Invalid usage is rejected at compile time:
//   %nil = eco.constant Nil : !eco.value
//   %bad = eco.construct.custom(%nil) {unboxed_bitmap = 1} : (!eco.value) -> !eco.value
//   ERROR: unboxed_bitmap bit 0 is set but field has boxed type '!eco.value'

module {
  func.func @main() -> i64 {
    %nil = eco.constant Nil : !eco.value
    %true = eco.constant True : !eco.value
    %false = eco.constant False : !eco.value
    %unit = eco.constant Unit : !eco.value
    %nothing = eco.constant Nothing : !eco.value

    // === Single constant field ===
    %c1 = eco.construct.custom(%nil) {tag = 1 : i64, size = 1 : i64} : (!eco.value) -> !eco.value
    eco.dbg %c1 : !eco.value
    // CHECK: Ctor1 []

    %c2 = eco.construct.custom(%true) {tag = 2 : i64, size = 1 : i64} : (!eco.value) -> !eco.value
    eco.dbg %c2 : !eco.value
    // CHECK: Ctor2 True

    %c3 = eco.construct.custom(%false) {tag = 3 : i64, size = 1 : i64} : (!eco.value) -> !eco.value
    eco.dbg %c3 : !eco.value
    // CHECK: Ctor3 False

    %c4 = eco.construct.custom(%unit) {tag = 4 : i64, size = 1 : i64} : (!eco.value) -> !eco.value
    eco.dbg %c4 : !eco.value
    // CHECK: Ctor4 ()

    %c5 = eco.construct.custom(%nothing) {tag = 5 : i64, size = 1 : i64} : (!eco.value) -> !eco.value
    eco.dbg %c5 : !eco.value
    // CHECK: Ctor5 Nothing

    // === Multiple constant fields ===
    %pair_consts = eco.construct.custom(%nil, %true) {tag = 10 : i64, size = 2 : i64} : (!eco.value, !eco.value) -> !eco.value
    eco.dbg %pair_consts : !eco.value
    // CHECK: Ctor10 [] True

    %triple_consts = eco.construct.custom(%true, %false, %nil) {tag = 11 : i64, size = 3 : i64} : (!eco.value, !eco.value, !eco.value) -> !eco.value
    eco.dbg %triple_consts : !eco.value
    // CHECK: Ctor11 True False []

    // === Project constants from structure ===
    %proj0 = eco.project.custom %pair_consts[0] : !eco.value -> !eco.value
    eco.dbg %proj0 : !eco.value
    // CHECK: []

    %proj1 = eco.project.custom %pair_consts[1] : !eco.value -> !eco.value
    eco.dbg %proj1 : !eco.value
    // CHECK: True

    // === Mix constants with boxed integers ===
    %i42 = arith.constant 42 : i64
    %b42 = eco.box %i42 : i64 -> !eco.value
    %i99 = arith.constant 99 : i64
    %b99 = eco.box %i99 : i64 -> !eco.value

    %mixed1 = eco.construct.custom(%b42, %nil) {tag = 20 : i64, size = 2 : i64} : (!eco.value, !eco.value) -> !eco.value
    eco.dbg %mixed1 : !eco.value
    // CHECK: Ctor20 42 []

    %mixed2 = eco.construct.custom(%true, %b99) {tag = 21 : i64, size = 2 : i64} : (!eco.value, !eco.value) -> !eco.value
    eco.dbg %mixed2 : !eco.value
    // CHECK: Ctor21 True 99

    %mixed3 = eco.construct.custom(%b42, %false, %b99) {tag = 22 : i64, size = 3 : i64} : (!eco.value, !eco.value, !eco.value) -> !eco.value
    eco.dbg %mixed3 : !eco.value
    // CHECK: Ctor22 42 False 99

    // === Mix constants with unboxed integers ===
    // unboxed_bitmap = 1 means field 0 is unboxed
    %i10 = arith.constant 10 : i64
    %mix_unboxed1 = eco.construct.custom(%i10, %nil) {tag = 30 : i64, size = 2 : i64, unboxed_bitmap = 1 : i64} : (i64, !eco.value) -> !eco.value
    eco.dbg %mix_unboxed1 : !eco.value
    // CHECK: Ctor30 10 []

    // unboxed_bitmap = 2 means field 1 is unboxed
    %i20 = arith.constant 20 : i64
    %mix_unboxed2 = eco.construct.custom(%true, %i20) {tag = 31 : i64, size = 2 : i64, unboxed_bitmap = 2 : i64} : (!eco.value, i64) -> !eco.value
    eco.dbg %mix_unboxed2 : !eco.value
    // CHECK: Ctor31 True 20

    // unboxed_bitmap = 5 (0b101) means fields 0 and 2 are unboxed
    %i30 = arith.constant 30 : i64
    %mix_unboxed3 = eco.construct.custom(%i10, %false, %i30) {tag = 32 : i64, size = 3 : i64, unboxed_bitmap = 5 : i64} : (i64, !eco.value, i64) -> !eco.value
    eco.dbg %mix_unboxed3 : !eco.value
    // CHECK: Ctor32 10 False 30

    // Project fields to verify values
    %p_unboxed = eco.project.custom %mix_unboxed3[0] : !eco.value -> i64
    eco.dbg %p_unboxed : i64
    // CHECK: 10

    %p_const = eco.project.custom %mix_unboxed3[1] : !eco.value -> !eco.value
    eco.dbg %p_const : !eco.value
    // CHECK: False

    // === List with Nil tail (Cons with constant) ===
    // This is the most common case: Cons cell with Nil as tail
    %list1 = eco.construct.custom(%b42, %nil) {tag = 0 : i64, size = 2 : i64} : (!eco.value, !eco.value) -> !eco.value
    eco.dbg %list1 : !eco.value
    // CHECK: Ctor0 42 []

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
