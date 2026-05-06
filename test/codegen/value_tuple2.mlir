// RUN: %ecoc %s -emit=mlir-llvm 2>&1 | %FileCheck %s
//
// Phase 0 escape-analysis plumbing: eco.make.tuple2 + eco.project.tuple2
// over a value-level tuple lower to LLVM struct insert/extract chains.
// Verify no heap allocation occurs.

module {
  func.func @value_tuple2_swap(%a: i64, %b: i64) -> i64 {
    %t = eco.make.tuple2 %a, %b : (i64, i64) -> !eco.tuple2<i64, i64>
    %x = eco.project.tuple2 %t[1] : !eco.tuple2<i64, i64> -> i64
    %y = eco.project.tuple2 %t[0] : !eco.tuple2<i64, i64> -> i64
    %sum = arith.addi %x, %y : i64
    return %sum : i64
  }
}

// CHECK: llvm.func @value_tuple2_swap
// CHECK: llvm.mlir.undef : !llvm.struct<(i64, i64)>
// CHECK: llvm.insertvalue
// CHECK: llvm.extractvalue
//
// No allocation must survive into the lowered LLVM dialect for a tuple
// that is built and immediately projected.
// CHECK-NOT: eco_alloc_tuple2
// CHECK-NOT: eco_resolve_hptr
