// RUN: %ecoc %s -emit=mlir-llvm -enable-unboxed-agg 2>&1 | %FileCheck %s
//
// Phase 3.4 #1: a function returning a tuple selected by `arith.select`
// across two construct sites. Pre‑3.4 this demoted because the return
// operand was defined by `arith.select`, which wasn't an accepted
// producer. Phase 3.4 walks both arms recursively, finds the construct
// leaves, and retypes the select's result to aggregate.

module {
  func.func @pick(%cond: i1, %a: i64, %b: i64) -> !eco.value
      attributes {
          eco.logical_param_types = ["i1", "i64", "i64"],
          eco.logical_result_types = ["tuple2:i:i"]
      } {
    %z = arith.constant 0 : i64
    %x = eco.construct.tuple2 %a, %z : i64, i64 -> !eco.value
    %y = eco.construct.tuple2 %z, %b : i64, i64 -> !eco.value
    %r = arith.select %cond, %x, %y : !eco.value
    return %r : !eco.value
  }
}

// Worker exists with i64, i64 params (after flatten) and the tuple
// result. Wrapper preserves the original boxed ABI:
// CHECK-DAG: llvm.func @pick$unboxed
// CHECK-DAG: llvm.func @pick(
//
// Neither construct.tuple2 remains in the worker — both were lifted
// to make.tuple2 and the boundary aggregate flows out via the
// flattened multi-return:
// CHECK-NOT: eco.construct.tuple2
