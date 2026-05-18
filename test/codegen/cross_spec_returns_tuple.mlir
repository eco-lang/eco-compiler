// RUN: %ecoc %s -emit=mlir-llvm -enable-unboxed-agg 2>&1 | %FileCheck %s
//
// Phase 3.1 #4 (result-side unboxing): a function returning a tuple
// of all-primitive elements is split into:
//   - a worker `@build_pair$unboxed` whose result is `!eco.tuple2<i64, i64>`
//     (after flatten: scalar i64, i64 multi-return)
//   - a wrapper `@build_pair` whose result stays `!eco.value`, with
//     `eco.to_heap` boxing the worker's aggregate result.
//
// The worker body rewrites `eco.construct.tuple2` → `eco.make.tuple2`
// so the return operand's SSA type lines up with the new worker result.

module {
  func.func @build_pair(%n: i64) -> !eco.value
      attributes {
          eco.logical_param_types = ["i64"],
          eco.logical_result_types = ["tuple2:i:i"]
      } {
    %one = arith.constant 1 : i64
    %m = arith.addi %n, %one : i64
    %t = eco.construct.tuple2 %n, %m : i64, i64 -> !eco.value
    return %t : !eco.value
  }
}

// Worker exists and has scalar-flattened multi-return signature:
// CHECK: llvm.func @build_pair$unboxed
// CHECK-SAME: -> !llvm.struct<(i64, i64)>
//
// Wrapper exists and boxes the worker result via eco_alloc_tuple2:
// CHECK: llvm.func @build_pair(
// CHECK: llvm.call @eco_alloc_tuple2
