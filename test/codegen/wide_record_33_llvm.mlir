// RUN: %ecoc %s -emit=mlir-llvm 2>&1 | %FileCheck %s
//
// Phase 3B: a 33-field record (32 boxed + one Int at slot 32) lowers with
// K = 1 extension kind word: header word = TagRecord(8) | K<<10 | 33<<32
// = 141733921800, the meta word holds kinds 0..31 (all boxed = 0), and the
// ext word at byte offset 16 + 8*33 = 280 holds slot 32's kind (Int = 1).
// emitExtKindWordStores creates the word constant before the offset constant.

module {
  func.func @wide33(%b: !eco.value, %i: i64) -> !eco.value {
    %r = eco.construct.record(%b, %b, %b, %b, %b, %b, %b, %b, %b, %b, %b, %b, %b, %b, %b, %b, %b, %b, %b, %b, %b, %b, %b, %b, %b, %b, %b, %b, %b, %b, %b, %b, %i) {field_count = 33 : i64, slot_kinds = array<i8: 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1>} : (!eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, i64) -> !eco.value
    return %r : !eco.value
  }
}

// CHECK: llvm.func @wide33
// CHECK: llvm.call @__eco_alloc_inline
// CHECK: llvm.mlir.constant(141733921800 : i64)
// CHECK: llvm.mlir.constant(1 : i64)
// CHECK: llvm.mlir.constant(280 : i64)
// CHECK: llvm.store
