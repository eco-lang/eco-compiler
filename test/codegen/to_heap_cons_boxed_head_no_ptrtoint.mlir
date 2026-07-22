// RUN: %ecoc %s -emit=mlir-llvm 2>&1 | %FileCheck %s
//
// Wrapper-fca-fix Chunk 2 (Fix C), updated for inline nursery allocation
// (plans/inline-nursery-allocation.md): the Cons `eco.to_heap` lowering for
// a boxed-head cons allocates via the `__eco_alloc_inline` bump marker and
// writes head/tail as barriered fresh stores (`__eco_hptr_to_slot`,
// REP_LLVM_002) — never a bare pre-alloc `ptrtoint` of the boxed head
// (GC-correctness across the slow-path safepoint).

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
// CHECK: llvm.call @__eco_alloc_inline
// Boxed head + tail land via the REP_LLVM_002 barriered fresh stores.
// CHECK: llvm.call @__eco_hptr_to_slot
// CHECK: llvm.store
// CHECK: llvm.call @__eco_hptr_to_slot
// CHECK: llvm.store
// No bare ptrtoint on the boxed head (the barrier is the only crossing).
// CHECK-NOT: llvm.ptrtoint
