// RUN: %ecoc %s -emit=mlir-llvm -enable-unboxed-agg 2>&1 | %FileCheck %s
//
// Phase 3.2 #1 result-side SCC propagation: a 2-member SCC where
// both members RETURN aggregates, and each member's recursive call
// result is directly forwarded as its own return. Result-side
// promotion requires the fixpoint to admit call-result-passthrough
// where the callee is in the same SCC with a matching tentative
// result shape — the unexercised branch of
// resultPositionHasAggregateProducer's same-SCC matching logic.

module {
  func.func @build_then(%n: i64) -> !eco.value
      attributes {
          eco.logical_param_types = ["i64"],
          eco.logical_result_types = ["tuple2:i:i"]
      } {
    %zero = arith.constant 0 : i64
    %is_zero = arith.cmpi eq, %n, %zero : i64
    %one = arith.constant 1 : i64
    %two = arith.constant 2 : i64
    %base = eco.construct.tuple2 %one, %two : i64, i64 -> !eco.value
    %nm1 = arith.subi %n, %one : i64
    %rec = "eco.call"(%nm1) {callee = @swap_then}
        : (i64) -> !eco.value
    %out = arith.select %is_zero, %base, %rec : !eco.value
    return %out : !eco.value
  }
  func.func @swap_then(%n: i64) -> !eco.value
      attributes {
          eco.logical_param_types = ["i64"],
          eco.logical_result_types = ["tuple2:i:i"]
      } {
    %zero = arith.constant 0 : i64
    %is_zero = arith.cmpi eq, %n, %zero : i64
    %three = arith.constant 3 : i64
    %four = arith.constant 4 : i64
    %base = eco.construct.tuple2 %three, %four : i64, i64 -> !eco.value
    %one = arith.constant 1 : i64
    %nm1 = arith.subi %n, %one : i64
    %rec = "eco.call"(%nm1) {callee = @build_then}
        : (i64) -> !eco.value
    %out = arith.select %is_zero, %base, %rec : !eco.value
    return %out : !eco.value
  }
}

// Both members get $unboxed workers — result-side promotion fires
// even though one of each return's producers is a same-SCC call:
// CHECK-DAG: llvm.func @build_then$unboxed
// CHECK-DAG: llvm.func @swap_then$unboxed
//
// Worker signatures multi-return two i64s (post-flatten scalarisation
// of !eco.tuple2<i64, i64> result). Regex matching tolerates any
// surrounding LLVM-dialect formatting:
// CHECK-DAG: @build_then$unboxed{{.*}}llvm.struct<\(i64, i64\)>
// CHECK-DAG: @swap_then$unboxed{{.*}}llvm.struct<\(i64, i64\)>
//
// Intra-SCC calls go to the worker variants — no roundtrip box/unbox
// on the result path:
// CHECK-DAG: llvm.call{{.*}}@swap_then$unboxed
// CHECK-DAG: llvm.call{{.*}}@build_then$unboxed
//
// External wrappers still allocate via eco_alloc_tuple2 for boxed
// callers (the boxed ABI is preserved):
// CHECK-DAG: @eco_alloc_tuple2
