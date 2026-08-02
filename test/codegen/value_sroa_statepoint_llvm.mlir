// RUN: %ecoc %s -emit=llvm 2>&1 | %FileCheck %s
//
// T1.3.0 mechanism spot-check (tier-1 plan, U-T1.3.0): a MIXED-element
// value aggregate — !eco.tuple2<i64, !eco.value> — must be fully
// scalarised by the pre-RS4GC LLVM pipeline (mem2reg → SROA →
// FoldExtractValue, `addEcoGCPipeline`) so that its GC-pointer element
// survives a statepoint as an ordinary relocated SSA value. This is the
// exact case RS4GC's "support for FCA unimplemented" assertion forbids
// when a struct carrying ptr addrspace(1) stays live across a
// statepoint — i.e. the load-bearing safety property of the whole
// aggregate-promotion mechanism (REP_AGG_001).
//
// The construct forces an allocation (inline-bump diamond, HEAP_034)
// whose slow path is a statepoint; the tuple's pointer element is live
// across it and must appear in the statepoint's gc-live bundle and be
// rebuilt via gc.relocate — never inside a struct.

module {
  func.func @sroa_mixed_probe(%n: i64, %p: !eco.value) -> !eco.value {
    %t = eco.make.tuple2 %n, %p : (i64, !eco.value) -> !eco.tuple2<i64, !eco.value>
    %x = eco.project.tuple2 %t[0] : !eco.tuple2<i64, !eco.value> -> i64
    %q = eco.project.tuple2 %t[1] : !eco.tuple2<i64, !eco.value> -> !eco.value
    %r = eco.construct.tuple2 %x, %q : i64, !eco.value -> !eco.value
    return %r : !eco.value
  }
}

// The function keeps scalar params — no aggregate reaches the ABI:
// CHECK: define ptr addrspace(1) @sroa_mixed_probe(i64 {{.*}}, ptr addrspace(1) {{.*}}) gc "eco-gc"
//
// The pointer element is tracked and relocated across the statepoint:
// CHECK: "gc-live"(ptr addrspace(1)
// CHECK: llvm.experimental.gc.relocate
//
// The aggregate itself must leave no residue after SROA/folding:
// CHECK-NOT: insertvalue
// CHECK-NOT: extractvalue
// CHECK-NOT: alloca
// CHECK-NOT: { i64, ptr addrspace(1) }
