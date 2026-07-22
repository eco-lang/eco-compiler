// RUN: %ecoc %s -emit=mlir-llvm 2>&1 | %FileCheck %s
//
// Phase 0: eco.to_heap on a !eco.record lowers to eco_alloc_record + per-field stores.

module {
  func.func @value_to_heap_record3(%x: i64, %y: !eco.value, %z: f64) -> !eco.value {
    %r = eco.make.record(%x, %y, %z)
       : (i64, !eco.value, f64) -> !eco.record<i64, !eco.value, f64>
    %h = eco.to_heap %r : (!eco.record<i64, !eco.value, f64>) -> !eco.value
    return %h : !eco.value
  }
}

// CHECK: llvm.func @value_to_heap_record3
// CHECK: llvm.call @__eco_alloc_inline
// P2.5 R5 Part 1 (plans/allocator-resolve-inlining.md §8.1): fresh-object
// stores are INLINE — barriered slot word (`__eco_hptr_to_slot` for boxed
// fields, REP_LLVM_002) + direct AS1 store; no eco_store_* runtime call.
// CHECK: llvm.store
// CHECK-NOT: llvm.call @eco_store_record_field
