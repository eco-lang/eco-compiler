// RUN: %ecoc %s -emit=mlir-llvm -enable-unboxed-agg 2>&1 | %FileCheck %s
//
// Phase 3.4 #1: a function returning a tuple produced by `eco.case`
// over a boolean scrutinee. Each alternative yields an `eco.construct.tuple2`
// — pre-3.4 the return operand (the case result) wasn't an accepted
// producer and the function demoted. Phase 3.4 widens `eco.case` to
// carry aggregate-typed results, walks both alternative regions'
// `eco.yield`s recursively, and retypes the chain.

module {
  func.func @pick(%cond: i1, %a: i64, %b: i64) -> !eco.value
      attributes {
          eco.logical_param_types = ["i1", "i64", "i64"],
          eco.logical_result_types = ["tuple2:i:i"]
      } {
    %z = arith.constant 0 : i64
    %r = eco.case %cond : i1 [0, 1] -> (!eco.value) { case_kind = "bool" } {
      // False arm (tag 0)
      %t = eco.construct.tuple2 %z, %b : i64, i64 -> !eco.value
      eco.yield %t : !eco.value
    }, {
      // True arm (tag 1)
      %t = eco.construct.tuple2 %a, %z : i64, i64 -> !eco.value
      eco.yield %t : !eco.value
    }
    return %r : !eco.value
  }
}

// Worker + wrapper exist; construct.tuple2 was lifted to make.tuple2
// in both alternatives so the eco.case result type is aggregate:
// CHECK-DAG: llvm.func @pick$unboxed
// CHECK-DAG: llvm.func @pick(
// CHECK-NOT: eco.construct.tuple2
