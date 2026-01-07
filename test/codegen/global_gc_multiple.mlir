// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test multiple globals with cross-references.
// Tests GC behavior with multiple global roots.

module {
  eco.global @g1
  eco.global @g2
  eco.global @g3

  func.func @main() -> i64 {
    // Create some values
    %i10 = arith.constant 10 : i64
    %i20 = arith.constant 20 : i64
    %i30 = arith.constant 30 : i64
    %b10 = eco.box %i10 : i64 -> !eco.value
    %b20 = eco.box %i20 : i64 -> !eco.value
    %b30 = eco.box %i30 : i64 -> !eco.value

    // Store in globals
    eco.store_global %b10, @g1
    eco.store_global %b20, @g2
    eco.store_global %b30, @g3

    // Read back and verify
    %r1 = eco.load_global @g1
    %r2 = eco.load_global @g2
    %r3 = eco.load_global @g3
    eco.dbg %r1 : !eco.value
    // CHECK: 10
    eco.dbg %r2 : !eco.value
    // CHECK: 20
    eco.dbg %r3 : !eco.value
    // CHECK: 30

    // Create a list that references multiple globals
    %nil = eco.constant Nil : !eco.value
    %list1 = eco.construct.custom(%r3, %nil) {tag = 0 : i64, size = 2 : i64} : (!eco.value, !eco.value) -> !eco.value
    %list2 = eco.construct.custom(%r2, %list1) {tag = 0 : i64, size = 2 : i64} : (!eco.value, !eco.value) -> !eco.value
    %list3 = eco.construct.custom(%r1, %list2) {tag = 0 : i64, size = 2 : i64} : (!eco.value, !eco.value) -> !eco.value
    eco.dbg %list3 : !eco.value
    // CHECK: Ctor0 10 (Ctor0 20 (Ctor0 30 []))

    // Store the list in g1 (creates cross-reference)
    eco.store_global %list3, @g1

    // Load and verify list is intact
    %loaded_list = eco.load_global @g1
    eco.dbg %loaded_list : !eco.value
    // CHECK: Ctor0 10 (Ctor0 20 (Ctor0 30 []))

    // Project elements from loaded list
    %head = eco.project.custom %loaded_list[0] : !eco.value -> !eco.value
    eco.dbg %head : !eco.value
    // CHECK: 10

    // Update g2 with a new value
    %i100 = arith.constant 100 : i64
    %b100 = eco.box %i100 : i64 -> !eco.value
    eco.store_global %b100, @g2

    // Verify g2 changed but g1, g3 unchanged
    %new_r1 = eco.load_global @g1
    %new_r2 = eco.load_global @g2
    %new_r3 = eco.load_global @g3
    eco.dbg %new_r2 : !eco.value
    // CHECK: 100
    eco.dbg %new_r3 : !eco.value
    // CHECK: 30

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
