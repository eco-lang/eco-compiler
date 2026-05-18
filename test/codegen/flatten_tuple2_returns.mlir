// RUN: %ecoc %s -emit=mlir-llvm -enable-unboxed-agg 2>&1 | %FileCheck %s
//
// Direct EcoFlattenAggBoundary test for aggregate-typed results.
// Worker tagged eco.unboxed_worker so cross-spec leaves it alone; only
// flatten transforms it. Worker returns !eco.tuple2<i64, i64> — after
// flatten, the function_type's result list becomes (i64, i64) and
// every func.return decomposes its operand via eco.project ops. The
// caller's func.call result list grows symmetrically, with an
// eco.make at the call site re-packing the multi-return so existing
// consumers see the original aggregate SSA value.

module {
  func.func private @build$unboxed(%n: i64) -> !eco.tuple2<i64, i64>
      attributes { eco.unboxed_worker } {
    %one = arith.constant 1 : i64
    %m = arith.addi %n, %one : i64
    %t = eco.make.tuple2 %n, %m : (i64, i64) -> !eco.tuple2<i64, i64>
    return %t : !eco.tuple2<i64, i64>
  }

  func.func @caller(%n: i64) -> i64 {
    %t = func.call @build$unboxed(%n) : (i64) -> !eco.tuple2<i64, i64>
    %a = eco.project.tuple2 %t[0] : !eco.tuple2<i64, i64> -> i64
    return %a : i64
  }
}

// Worker returns an LLVM struct of (i64, i64) — multi-return func.func
// lowers to a struct-returning llvm.func:
// CHECK: llvm.func @build$unboxed
// CHECK-SAME: -> !llvm.struct<(i64, i64)>
//
// Caller still has scalar ABI; flatten inserts insertvalue at the
// call site to re-pack the multi-return into the original aggregate
// SSA shape, then extractvalue projects the first field:
// CHECK: llvm.func @caller
// CHECK: llvm.call @build$unboxed
// CHECK: llvm.insertvalue
// CHECK: llvm.extractvalue
