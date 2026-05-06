// RUN: %ecoc %s -emit=mlir-llvm -enable-unboxed-agg 2>&1 | %FileCheck %s
//
// Phase 2 prerequisite: with SROA wired before RS4GC, value-level
// aggregates carrying boxed (`!eco.value` → `ptr addrspace(1)`) fields
// can be rewritten safely. The struct is broken back into independent
// SSA values by mem2reg + SROA before RS4GC sees it, so the
// "FCA unimplemented" assertion that gated Phase 1 no longer applies.
//
// This fixture exercises a mixed-kind Tuple2 — (i64, !eco.value) — and
// a fully-boxed Tuple2 — (!eco.value, !eco.value). Both must rewrite
// to insertvalue/extractvalue chains and emit no eco_alloc_tuple2 call.

module {
  func.func @local_mixed_tuple(%a: i64, %b: !eco.value) -> !eco.value {
    %t = eco.construct.tuple2 %a, %b : i64, !eco.value -> !eco.value
    %x = eco.project.tuple2 %t[1] : !eco.value -> !eco.value
    return %x : !eco.value
  }

  func.func @local_boxed_tuple(%a: !eco.value, %b: !eco.value) -> !eco.value {
    %t = eco.construct.tuple2 %a, %b : !eco.value, !eco.value -> !eco.value
    %x = eco.project.tuple2 %t[0] : !eco.value -> !eco.value
    return %x : !eco.value
  }
}

// CHECK: llvm.func @local_mixed_tuple
// CHECK: llvm.mlir.undef : !llvm.struct<(i64, ptr<1>)>
// CHECK: llvm.insertvalue
// CHECK: llvm.extractvalue
//
// CHECK: llvm.func @local_boxed_tuple
// CHECK: llvm.mlir.undef : !llvm.struct<(ptr<1>, ptr<1>)>
// CHECK: llvm.insertvalue
// CHECK: llvm.extractvalue
//
// Neither function may retain a heap allocation.
// CHECK-NOT: eco_alloc_tuple2
