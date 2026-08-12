// RUN: %ecoc %s -emit=llvm 2>&1 | %FileCheck %s --check-prefix=SPLIT
// RUN: env ECO_GCPREPARE_SPLIT_INLINE_GROUPS=0 %ecoc %s -emit=llvm 2>&1 | %FileCheck %s --check-prefix=GROUP
//
// kernel-opt-09 Phase 2-pre: EcoGCPrepare must NOT group a run of adjacent
// allocations when every member already has a call-free HEAP_034 inline
// lowering, because grouping such a run is a pessimization, not an
// optimization:
//
//   grouped   -> one out-of-line `eco_gc_alloc_region_fast` (+ its slow twin)
//                plus one `eco_init_tuple2_at` runtime call PER MEMBER
//                (EcoToLLVMHeap.cpp lowerOneAllocGroup / emitInitAtPtr)
//   ungrouped -> one inline bump per member, header and fields stored
//                straight-line, and NO calls at all
//
// The two tuple2 constructs below are adjacent and independent (the second
// swaps the operands rather than consuming the first), so today's Step-1
// grouping WOULD form a group of two. That is exactly the shape the Phase-1
// census found 1,385 of in the compiler's own module.
//
// This file is the pin for both directions: the default path must be call-free,
// and the kill switch must restore the group form byte-for-byte in kind. The
// entire allocation-group lowering had no fixture before this one.

module {
  func.func @main() -> i64 {
    %a = eco.string_literal "x" : !eco.value
    %b = eco.string_literal "y" : !eco.value
    %t = eco.construct.tuple2 %a, %b : !eco.value, !eco.value -> !eco.value
    %u = eco.construct.tuple2 %b, %a : !eco.value, !eco.value -> !eco.value
    eco.dbg %t : !eco.value
    eco.dbg %u : !eco.value
    %z = arith.constant 0 : i64
    return %z : i64
  }
}

// Default (split ON): allocation goes through the inline bump — the nursery
// bump state is read directly and the only call on the path is the slow-path
// escape hatch, which is not on the fast path.
// SPLIT: @eco_bump_state
// SPLIT: @eco_alloc_inline_slow
//
// Not one out-of-line region allocation, and not one per-member init call.
// SPLIT-NOT: eco_gc_alloc_region_fast
// SPLIT-NOT: eco_gc_alloc_region_slow
// SPLIT-NOT: eco_init_tuple2_at

// Kill switch (split OFF): the group form is back — a region allocation with
// its null-check diamond, and one init call per member in each of the fast and
// slow blocks.
// GROUP: eco_gc_alloc_region_fast
// GROUP: eco_init_tuple2_at
// GROUP: eco_gc_alloc_region_slow
