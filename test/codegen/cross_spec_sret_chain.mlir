// RUN: %ecoc %s -emit=mlir-llvm -enable-unboxed-agg 2>&1 | %FileCheck %s
//
// Phase 3.3 inter-worker sret: a two-function chain where `f` calls
// `g` and both return a tuple containing an `!eco.value` element.
// After cross-spec both have $unboxed workers; the intra-worker call
// from `f$unboxed` to `g$unboxed` allocates a local sret slot,
// passes it as the leading operand, then loads the fields back to
// rebuild the aggregate without a heap round-trip.

module {
  func.func @g(%n: i64, %b: !eco.value) -> !eco.value
      attributes {
          eco.logical_param_types = ["i64", "value"],
          eco.logical_result_types = ["tuple2:i:v"]
      } {
    %t = eco.construct.tuple2 %n, %b : i64, !eco.value -> !eco.value
    return %t : !eco.value
  }

  func.func @f(%n: i64, %b: !eco.value) -> !eco.value
      attributes {
          eco.logical_param_types = ["i64", "value"],
          eco.logical_result_types = ["tuple2:i:v"]
      } {
    %g_result = func.call @g(%n, %b) : (i64, !eco.value) -> !eco.value
    %lhs = eco.project.tuple2 %g_result[0] : !eco.value -> i64
    %rhs = eco.project.tuple2 %g_result[1] : !eco.value -> !eco.value
    %t = eco.construct.tuple2 %lhs, %rhs : i64, !eco.value -> !eco.value
    return %t : !eco.value
  }
}

// Both workers exist:
// CHECK-DAG: llvm.func @g$unboxed
// CHECK-DAG: llvm.func @f$unboxed
//
// `f$unboxed` allocates the slot for the `g$unboxed` call result, then
// invokes the worker directly:
// CHECK-DAG: llvm.func @f$unboxed
// CHECK: llvm.alloca
// CHECK: llvm.call @g$unboxed
//
// Both wrappers preserve the original boxed ABI:
// CHECK-DAG: llvm.func @g(
// CHECK-DAG: llvm.func @f(
