// RUN: %ecoc %s -emit=llvm -enable-unboxed-agg 2>&1 | %FileCheck %s
//
// Phase 3.2 #2 LLVM-IR validation for the multi-return result case.
// MLIR's func.func with multiple results lowers to llvm.func with
// a struct return. For an all-primitive aggregate result this is
// safe — RS4GC accepts the struct because no GC pointer lives
// inside. The harness verifies the worker has the expected
// `{ i64, i64 }` return shape and that the wrapper uses
// extractvalue on the return (not an alloca) to recover the scalar
// fields before re-boxing via eco_alloc_tuple2.
//
// The CHECK-NOT: alloca line catches a hypothetical regression
// where SROA fails to scalarise the worker's local make.tuple2
// (which lowers to insertvalue at the SSA level, and may go through
// an alloca if SROA fails).

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

// Worker returns an LLVM struct of two i64 scalars (multi-result
// func.func lowers to struct-returning llvm.func — no ptr<1> in the
// struct, so RS4GC accepts it):
// CHECK: define { i64, i64 } @"build_pair$unboxed"(i64 %0)
//
// Wrapper has the original boxed ABI:
// CHECK: define ptr addrspace(1) @build_pair(i64 %0)
//
// Wrapper extracts the worker's struct return then boxes via
// eco_alloc_tuple2 — no alloca path:
// CHECK: call { i64, i64 } @llvm.experimental.gc.result
// CHECK: extractvalue { i64, i64 }
// CHECK: @eco_alloc_tuple2
//
// SROA eliminated any stack-allocated boundary struct:
// CHECK-NOT: alloca
