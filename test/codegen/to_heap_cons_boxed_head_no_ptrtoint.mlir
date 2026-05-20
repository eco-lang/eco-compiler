// RUN: %ecoc %s -emit=mlir-llvm 2>&1 | %FileCheck %s
//
// Wrapper-fca-fix Chunk 2 (Fix C): the Cons `eco.to_heap` lowering for a
// boxed-head cons must allocate via `eco_alloc_cons_uninit(head_kind)`
// and write the head via `eco_store_cons_head` (which takes the head
// as ptr addrspace(1)) and the tail via `eco_store_cons_tail` — never
// a pre-alloc `ptrtoint` of the boxed head. See Fix C in
// plans/wrapper-fca-fix.md for the rationale (GC-correctness on the
// alloc safepoint).

module {
  func.func @to_heap_cons_boxed_head(%h: !eco.value, %t: !eco.value) -> !eco.value {
    %c = eco.make.cons %h, %t
       : (!eco.value, !eco.value) -> !eco.cons<!eco.value, !eco.value>
    %r = eco.to_heap %c {head_kind = 0 : i64, head_unboxed = false}
       : (!eco.cons<!eco.value, !eco.value>) -> !eco.value
    return %r : !eco.value
  }
}

// CHECK: llvm.func @to_heap_cons_boxed_head
// CHECK: llvm.call @eco_alloc_cons_uninit
// CHECK: llvm.call @eco_store_cons_head(
// CHECK: llvm.call @eco_store_cons_tail(
// No pre-alloc ptrtoint on the boxed head.
// CHECK-NOT: llvm.ptrtoint
