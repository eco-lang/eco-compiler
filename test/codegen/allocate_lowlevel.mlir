// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test low-level allocation operations.
// Note: eco.allocate_closure requires a function reference, but user-defined
// functions can't be translated to LLVM IR in current setup, so we test
// allocate_string here; the constructor cases (formerly eco.allocate_ctor,
// deleted with its scalar_bytes ABI in wide-object Phase 3A) use
// eco.construct.custom.

module {
  func.func @main() -> i64 {
    %c1 = arith.constant 1 : i64
    %c2 = arith.constant 2 : i64
    %c3 = arith.constant 3 : i64
    %b1 = eco.box %c1 : i64 -> !eco.value
    %b2 = eco.box %c2 : i64 -> !eco.value
    %b3 = eco.box %c3 : i64 -> !eco.value

    // tag=5, 2 fields
    %ctor_obj = eco.construct.custom(%b1, %b2) {slot_kinds = array<i8: 0, 0>, tag = 5 : i64, size = 2 : i64} : (!eco.value, !eco.value) -> !eco.value
    eco.dbg %ctor_obj : !eco.value
    // CHECK: Ctor5 1 2

    // different tag, 3 fields
    %ctor_obj2 = eco.construct.custom(%b1, %b2, %b3) {slot_kinds = array<i8: 0, 0, 0>, tag = 0 : i64, size = 3 : i64} : (!eco.value, !eco.value, !eco.value) -> !eco.value
    eco.dbg %ctor_obj2 : !eco.value
    // CHECK: Ctor0 1 2 3

    // tag 10, 1 field
    %ctor_obj3 = eco.construct.custom(%b3) {slot_kinds = array<i8: 0>, tag = 10 : i64, size = 1 : i64} : (!eco.value) -> !eco.value
    eco.dbg %ctor_obj3 : !eco.value
    // CHECK: Ctor10 3

    // eco.allocate_string - allocate string storage
    %str_storage = eco.allocate_string {length = 5 : i64} : !eco.value
    eco.dbg %str_storage : !eco.value
    // CHECK: "

    // eco.allocate_string with different length
    %str_storage2 = eco.allocate_string {length = 10 : i64} : !eco.value
    eco.dbg %str_storage2 : !eco.value
    // CHECK: "

    // a 2-field ctor nesting another
    %ctor = eco.construct.custom(%ctor_obj3, %b2) {slot_kinds = array<i8: 0, 0>, tag = 7 : i64, size = 2 : i64} : (!eco.value, !eco.value) -> !eco.value
    eco.dbg %ctor : !eco.value
    // CHECK: Ctor7 (Ctor10 3) 2

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
