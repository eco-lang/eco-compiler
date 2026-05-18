// RUN: %ecoc %s -emit=mlir-llvm -enable-unboxed-agg 2>&1 | %FileCheck %s
//
// Phase 3.2 #1: two mutually-recursive functions form an SCC of
// size 2. Both share a tuple2 aggregate param. The inner-SCC
// fixpoint promotes both members atomically — calls between them
// thread the aggregate operand through the matching slot, demotion
// in either side cascades into the other (mutual-shape-consistency).
//
// Replaces the pre-3.2 negative sentinel
// cross_spec_mutual_recursive_skipped.mlir.

module {
  func.func @ping(%t: !eco.value, %n: i64) -> i64
      attributes {
          eco.logical_param_types = ["tuple2:i:i", "i64"],
          eco.logical_result_types = ["i64"]
      } {
    %zero = arith.constant 0 : i64
    %is_zero = arith.cmpi eq, %n, %zero : i64
    %a = eco.project.tuple2 %t[0] : !eco.value -> i64
    %one = arith.constant 1 : i64
    %nm1 = arith.subi %n, %one : i64
    %r = "eco.call"(%t, %nm1) {callee = @pong}
        : (!eco.value, i64) -> i64
    %out = arith.select %is_zero, %a, %r : i64
    return %out : i64
  }

  func.func @pong(%t: !eco.value, %n: i64) -> i64
      attributes {
          eco.logical_param_types = ["tuple2:i:i", "i64"],
          eco.logical_result_types = ["i64"]
      } {
    %zero = arith.constant 0 : i64
    %is_zero = arith.cmpi eq, %n, %zero : i64
    %b = eco.project.tuple2 %t[1] : !eco.value -> i64
    %one = arith.constant 1 : i64
    %nm1 = arith.subi %n, %one : i64
    %r = "eco.call"(%t, %nm1) {callee = @ping}
        : (!eco.value, i64) -> i64
    %out = arith.select %is_zero, %b, %r : i64
    return %out : i64
  }
}

// Both members of the SCC get $unboxed workers:
// CHECK-DAG: llvm.func @ping$unboxed
// CHECK-DAG: llvm.func @pong$unboxed
//
// Wrappers exist for the external ABI:
// CHECK-DAG: llvm.func @ping(
// CHECK-DAG: llvm.func @pong(
//
// Intra-SCC calls thread directly through the worker variants —
// no box/unbox round-trip at every recursive step:
// CHECK-DAG: llvm.call @pong$unboxed
// CHECK-DAG: llvm.call @ping$unboxed
