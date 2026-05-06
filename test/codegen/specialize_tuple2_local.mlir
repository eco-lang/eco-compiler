// RUN: %ecoc %s -emit=mlir-llvm -enable-unboxed-agg 2>&1 | %FileCheck %s
//
// Phase 1: a Tuple2 with primitive (i64, i64) elements built and
// immediately projected, never escaping the function, gets rewritten by
// EcoEscapeAnalysisPass + EcoUnboxedAggSpecialize into eco.make.tuple2
// -> LLVM struct insert/extract chain.
//
// Phase 1 deliberately restricts the rewrite to all-primitive tuples
// because LLVM's RS4GC asserts "support for FCA unimplemented" for
// first-class aggregates carrying ptr addrspace(1) fields when live
// across a statepoint. All-primitive tuples cannot carry GC pointers,
// so they are safe regardless of SROA timing.
//
// Identical input compiled WITHOUT -enable-unboxed-agg still allocates;
// see specialize_off_default.mlir for that side of the contract.

module {
  func.func @local_tuple(%a: i64, %b: i64) -> i64 {
    %t = eco.construct.tuple2 %a, %b : i64, i64 -> !eco.value
    %x = eco.project.tuple2 %t[0] : !eco.value -> i64
    return %x : i64
  }
}

// CHECK: llvm.func @local_tuple
// CHECK: llvm.mlir.undef : !llvm.struct<(i64, i64)>
// CHECK: llvm.insertvalue
// CHECK: llvm.extractvalue
//
// The non-escaping construct must NOT survive as a heap allocation.
// CHECK-NOT: eco_alloc_tuple2
// CHECK-NOT: eco.construct.tuple2
