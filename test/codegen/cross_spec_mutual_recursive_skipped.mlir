// RUN: %ecoc %s -emit=mlir-llvm -enable-unboxed-agg 2>&1 | %FileCheck %s
//
// Phase 3.1 #5 SCC disqualification: two functions that mutually call
// each other form an SCC of size 2. The fixpoint pass must conservatively
// SKIP both — Phase 3.2 will lift this restriction. The functions still
// run correctly via the heap path; they just don't get $unboxed workers.

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
    %r = "eco.call"(%t, %nm1) {callee = @pong} : (!eco.value, i64) -> i64
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
    %r = "eco.call"(%t, %nm1) {callee = @ping} : (!eco.value, i64) -> i64
    %out = arith.select %is_zero, %b, %r : i64
    return %out : i64
  }
}

// Neither function should get a $unboxed worker (SCC size 2 is
// disqualified in Phase 3.1; 3.2 lifts this).
// CHECK-NOT: @ping$unboxed
// CHECK-NOT: @pong$unboxed
//
// Both functions still exist in their boxed form:
// CHECK-DAG: llvm.func @ping(
// CHECK-DAG: llvm.func @pong(
