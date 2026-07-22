// RUN: %ecoc %s -emit=mlir-llvm 2>&1 | %FileCheck %s
//
// Phase 1: when -enable-unboxed-agg is NOT passed, even a fully local
// all-primitive Tuple2 stays as a heap allocation. This is the
// off-by-default sanity test: the existing pipeline must not change
// behaviour when the flag is absent.

module {
  func.func @local_tuple_default(%a: i64, %b: i64) -> i64 {
    %t = eco.construct.tuple2 %a, %b : i64, i64 -> !eco.value
    %x = eco.project.tuple2 %t[0] : !eco.value -> i64
    return %x : i64
  }
}

// CHECK: llvm.func @local_tuple_default
// CHECK: llvm.call @__eco_alloc_inline
//
// Aggregate-form lowering must NOT appear without the flag.
// CHECK-NOT: llvm.struct<(i64, i64)>
