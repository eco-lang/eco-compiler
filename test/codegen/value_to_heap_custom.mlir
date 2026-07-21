// RUN: %ecoc %s -emit=mlir-llvm 2>&1 | %FileCheck %s
//
// Phase 0: eco.to_heap on a !eco.custom lowers to eco_alloc_custom + per-field stores.

module {
  func.func @value_to_heap_custom(%inner: !eco.value) -> !eco.value {
    %c = eco.make.custom(%inner) {tag = 1 : i64, constructor = "Just"}
       : (!eco.value) -> !eco.custom<!eco.value>
    %h = eco.to_heap %c {tag = 1 : i64} : (!eco.custom<!eco.value>) -> !eco.value
    return %h : !eco.value
  }
}

// CHECK: llvm.func @value_to_heap_custom
// CHECK: llvm.call @eco_alloc_custom
// P2.5 R5 Part 1 (plans/allocator-resolve-inlining.md §8.1): fresh-object
// stores are INLINE — barriered slot word (`__eco_hptr_to_slot` for boxed
// fields, REP_LLVM_002) + direct AS1 store; no eco_store_* runtime call.
// CHECK: llvm.store
// CHECK-NOT: llvm.call @eco_store_field
