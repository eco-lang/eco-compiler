// RUN: %ecoc %s -emit=mlir-llvm -enable-unboxed-agg 2>&1 | %FileCheck %s
//
// Phase 1: a Tuple2 built and immediately projected, never escaping the
// function, gets rewritten by EcoEscapeAnalysisPass + EcoUnboxedAggSpecialize
// into eco.make.tuple2 -> LLVM struct insert/extract chain.
//
// Identical input compiled WITHOUT -enable-unboxed-agg still allocates;
// see specialize_off_default.mlir for that side of the contract.

module {
  func.func @local_tuple(%a: !eco.value, %b: !eco.value) -> !eco.value {
    %t = eco.construct.tuple2 %a, %b : !eco.value, !eco.value -> !eco.value
    %x = eco.project.tuple2 %t[0] : !eco.value -> !eco.value
    return %x : !eco.value
  }
}

// CHECK: llvm.func @local_tuple
// CHECK: llvm.mlir.undef : !llvm.struct<(ptr<1>, ptr<1>)>
// CHECK: llvm.insertvalue
// CHECK: llvm.extractvalue
//
// The non-escaping construct must NOT survive as a heap allocation.
// CHECK-NOT: eco_alloc_tuple2
// CHECK-NOT: eco.construct.tuple2
