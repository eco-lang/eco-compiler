// RUN: %ecoc %s -emit=mlir-llvm 2>&1 | %FileCheck %s
//
// Phase 1: when -enable-unboxed-agg is NOT passed, even a fully local
// Tuple2 stays as a heap allocation. This is the off-by-default sanity
// test: the existing pipeline must not change behaviour when the flag
// is absent.

module {
  func.func @local_tuple_default(%a: !eco.value, %b: !eco.value) -> !eco.value {
    %t = eco.construct.tuple2 %a, %b : !eco.value, !eco.value -> !eco.value
    %x = eco.project.tuple2 %t[0] : !eco.value -> !eco.value
    return %x : !eco.value
  }
}

// CHECK: llvm.func @local_tuple_default
// CHECK: llvm.call @eco_alloc_tuple2
//
// Aggregate-form lowering must NOT appear without the flag.
// CHECK-NOT: llvm.struct<(ptr<1>, ptr<1>)>
