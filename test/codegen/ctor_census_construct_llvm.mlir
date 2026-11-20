// RUN: %ecoc %s -emit=llvm 2>&1 | %FileCheck %s
//
// The constructor census (plans/constructor-representation-levels.md, unit M0): an
// eco.construct.custom carrying `_census_id` counts its execution through the gc-leaf
// `eco_ctor_census_count(id, 0)` and, on the inline allocation path, keeps the id in the
// header's 15 `refcount` bits (bit 16 up), so the minor GC can attribute its promotion. An
// eco.make.custom with the attribute counts as an SSA construction, `which` 1. An op without
// the attribute emits no call.

module {
  func.func @main() -> i64 {
    %i = arith.constant 42 : i64
    %b = eco.box %i : i64 -> !eco.value
    // CHECK: call {{.*}}@eco_ctor_census_count(i32 5, i32 0)
    // Header: tag 7 (Custom), size 1, census id 5 in bits 16-30: 0x1_0005_0007.
    // CHECK: store i64 4295294983
    %c = eco.construct.custom(%b) <{slot_kinds = array<i8: 0>, tag = 0 : i64, size = 1 : i64}> {_census_id = 5 : i64} : (!eco.value) -> !eco.value
    %d = eco.construct.custom(%b) <{slot_kinds = array<i8: 0>, tag = 1 : i64, size = 1 : i64}> : (!eco.value) -> !eco.value
    eco.dbg %c : !eco.value
    eco.dbg %d : !eco.value
    %r = arith.constant 0 : i64
    return %r : i64
  }
}
