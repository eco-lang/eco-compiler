// RUN: %ecoc %s -emit=mlir-llvm 2>&1 | %FileCheck %s
//
// Wrapper-fca-fix Chunk 1 (Fix B): the Record `eco.to_heap` lowering must
// pre-extract every aggregate field BEFORE calling `eco_alloc_record`, so
// the register-form FCA over `ptr addrspace(1)` fields stays out of the
// alloc safepoint's live set. Without this reorder, RS4GC's
// "support for FCA unimplemented" assertion fires whenever the matching
// extractvalue chain can't be folded back to its insertvalue inputs
// (Shape A in plans/wrapper-fca-fix.md §1.0).

module {
  func.func @to_heap_record_two_boxed(%x: !eco.value, %y: !eco.value) -> !eco.value {
    %r = eco.make.record(%x, %y)
       : (!eco.value, !eco.value) -> !eco.record<!eco.value, !eco.value>
    %h = eco.to_heap %r : (!eco.record<!eco.value, !eco.value>) -> !eco.value
    return %h : !eco.value
  }
}

// Every field is extracted (via llvm.extractvalue) BEFORE eco_alloc_record
// — confirmed by the order of CHECK lines below. FileCheck enforces
// in-order matching, so the two extractvalues must appear ahead of the
// alloc call.
// CHECK: llvm.func @to_heap_record_two_boxed
// CHECK: llvm.extractvalue
// CHECK: llvm.extractvalue
// CHECK: llvm.call @eco_alloc_record
// P2.5 R5 Part 1 (plans/allocator-resolve-inlining.md §8.1): fresh-object
// stores are INLINE — barriered slot word (`__eco_hptr_to_slot` for boxed
// fields, REP_LLVM_002) + direct AS1 store; no eco_store_* runtime call.
// CHECK: llvm.call @__eco_hptr_to_slot
// CHECK: llvm.store
// CHECK: llvm.call @__eco_hptr_to_slot
// CHECK: llvm.store
// CHECK-NOT: llvm.call @eco_store_record_field
