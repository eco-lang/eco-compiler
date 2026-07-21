// RUN: %ecoc %s -emit=mlir-llvm 2>&1 | %FileCheck %s
//
// Wrapper-fca-fix Chunk 2 (Fix C): the Tuple2 `eco.to_heap` lowering for
// a tuple carrying `!eco.value` fields must allocate via
// `eco_alloc_tuple2_uninit` (taking only the bitmap) and then write
// each boxed field via `eco_store_tuple_field` (which takes the field
// as ptr addrspace(1) directly). The pre-Fix-C path used
// `eco_alloc_tuple2(i64 a, i64 b, i32 bitmap)`, requiring a pre-alloc
// `ptrtoint` per boxed field — that stripped GC-pointer status before
// the alloc safepoint, so RS4GC didn't relocate the values, and a
// collection between alloc and store could leave the new tuple holding
// stale i64s. The uninit + store_field shape lets RS4GC track the
// values as live ptr<1>s across the alloc and stores instead.

module {
  func.func @to_heap_tuple2_two_boxed(%a: !eco.value, %b: !eco.value) -> !eco.value {
    %t = eco.make.tuple2 %a, %b
       : (!eco.value, !eco.value) -> !eco.tuple2<!eco.value, !eco.value>
    %h = eco.to_heap %t
       : (!eco.tuple2<!eco.value, !eco.value>) -> !eco.value
    return %h : !eco.value
  }
}

// CHECK: llvm.func @to_heap_tuple2_two_boxed
// New ABI: alloc-uninit + per-field store helpers for boxed slots.
// CHECK: llvm.call @eco_alloc_tuple2_uninit
// P2.5 R5 Part 1 (plans/allocator-resolve-inlining.md §8.1): fresh-object
// stores are INLINE — barriered slot word (`__eco_hptr_to_slot` for boxed
// fields, REP_LLVM_002) + direct AS1 store; no eco_store_* runtime call.
// CHECK: llvm.call @__eco_hptr_to_slot
// CHECK: llvm.store
// CHECK: llvm.call @__eco_hptr_to_slot
// CHECK: llvm.store
// CHECK-NOT: llvm.call @eco_store_tuple_field
// And — the smoking gun against the pre-Fix-C lowering — no ptrtoint
// in the boxed-field path:
// CHECK-NOT: llvm.ptrtoint
