// RUN: %ecoc %s -emit=mlir-llvm -enable-unboxed-agg 2>&1 | %FileCheck %s
//
// Phase 3.1 #4 (relaxed result-side eligibility): a function that just
// forwards another eligible function's aggregate-typed result must
// itself become eligible. The fixpoint admits `func.call`/`eco.call`
// producers when the callee is in the eligible set and its matching
// result is promoted to a compatible aggregate.
//
// Test shape: @leaf produces a tuple2 via construct; @middle just
// forwards @leaf's result; @outer forwards @middle's. All three
// should get $unboxed workers after the fixpoint converges.

module {
  func.func @leaf(%x: i64) -> !eco.value
      attributes {
          eco.logical_param_types = ["i64"],
          eco.logical_result_types = ["tuple2:i:i"]
      } {
    %one = arith.constant 1 : i64
    %y = arith.addi %x, %one : i64
    %t = eco.construct.tuple2 %x, %y : i64, i64 -> !eco.value
    return %t : !eco.value
  }

  func.func @middle(%x: i64) -> !eco.value
      attributes {
          eco.logical_param_types = ["i64"],
          eco.logical_result_types = ["tuple2:i:i"]
      } {
    %r = "eco.call"(%x) {callee = @leaf} : (i64) -> !eco.value
    return %r : !eco.value
  }

  func.func @outer(%x: i64) -> !eco.value
      attributes {
          eco.logical_param_types = ["i64"],
          eco.logical_result_types = ["tuple2:i:i"]
      } {
    %r = "eco.call"(%x) {callee = @middle} : (i64) -> !eco.value
    return %r : !eco.value
  }
}

// All three workers exist (call-result passthrough fixpoint):
// CHECK-DAG: llvm.func @leaf$unboxed
// CHECK-DAG: llvm.func @middle$unboxed
// CHECK-DAG: llvm.func @outer$unboxed
//
// Wrappers exist for the external ABI:
// CHECK-DAG: llvm.func @leaf(
// CHECK-DAG: llvm.func @middle(
// CHECK-DAG: llvm.func @outer(
//
// Worker bodies forward through other $unboxed workers (no roundtrip):
// CHECK-DAG: llvm.call @leaf$unboxed
// CHECK-DAG: llvm.call @middle$unboxed
