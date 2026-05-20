// RUN: %ecoc %s -emit=mlir-llvm 2>&1 | %FileCheck %s
//
// Wrapper-fca-fix Chunk 1 (Fix B): the Custom `eco.to_heap` lowering must
// pre-extract every aggregate field BEFORE calling `eco_alloc_custom`,
// same reasoning as the Record companion fixture. Without the reorder,
// the FCA over boxed (`ptr addrspace(1)`) fields is live across the
// alloc safepoint and trips RS4GC's "support for FCA unimplemented"
// assertion when the matching extracts can't be folded.

module {
  func.func @to_heap_custom_two_boxed(%x: !eco.value, %y: !eco.value) -> !eco.value {
    %c = eco.make.custom(%x, %y) {tag = 0 : i64}
       : (!eco.value, !eco.value) -> !eco.custom<!eco.value, !eco.value>
    %h = eco.to_heap %c {tag = 0 : i64}
       : (!eco.custom<!eco.value, !eco.value>) -> !eco.value
    return %h : !eco.value
  }
}

// Extracts precede the alloc; stores follow.
// CHECK: llvm.func @to_heap_custom_two_boxed
// CHECK: llvm.extractvalue
// CHECK: llvm.extractvalue
// CHECK: llvm.call @eco_alloc_custom
// CHECK: llvm.call @eco_store_field
// CHECK: llvm.call @eco_store_field
