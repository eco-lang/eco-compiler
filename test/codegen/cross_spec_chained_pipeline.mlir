// RUN: %ecoc %s -emit=mlir-llvm -enable-unboxed-agg 2>&1 | %FileCheck %s
//
// Phase 3.1 #5 (DAG fixpoint): a 3-function DAG `f → g → h` where
// every function takes a tuple2 param and h is a leaf becomes
// uniformly eligible after the fixpoint propagation. After cross-
// spec + flatten, the chain calls flow through `$unboxed` workers
// with scalar (i64, i64) signatures end-to-end — no intermediate
// box/unbox at any call boundary inside the chain.

module {
  func.func @h(%t: !eco.value) -> i64
      attributes {
          eco.logical_param_types = ["tuple2:i:i"],
          eco.logical_result_types = ["i64"]
      } {
    %a = eco.project.tuple2 %t[0] : !eco.value -> i64
    %b = eco.project.tuple2 %t[1] : !eco.value -> i64
    %s = arith.addi %a, %b : i64
    return %s : i64
  }

  func.func @g(%t: !eco.value) -> i64
      attributes {
          eco.logical_param_types = ["tuple2:i:i"],
          eco.logical_result_types = ["i64"]
      } {
    %r = "eco.call"(%t) {callee = @h} : (!eco.value) -> i64
    return %r : i64
  }

  func.func @f(%t: !eco.value) -> i64
      attributes {
          eco.logical_param_types = ["tuple2:i:i"],
          eco.logical_result_types = ["i64"]
      } {
    %r = "eco.call"(%t) {callee = @g} : (!eco.value) -> i64
    return %r : i64
  }
}

// All three workers exist:
// CHECK-DAG: llvm.func @h$unboxed
// CHECK-DAG: llvm.func @g$unboxed
// CHECK-DAG: llvm.func @f$unboxed
//
// Wrappers exist (called from outside the chain):
// CHECK-DAG: llvm.func @h(
// CHECK-DAG: llvm.func @g(
// CHECK-DAG: llvm.func @f(
//
// Worker bodies redirect inter-chain calls to other $unboxed workers
// instead of round-tripping through wrappers:
// CHECK-DAG: llvm.call @h$unboxed
// CHECK-DAG: llvm.call @g$unboxed
