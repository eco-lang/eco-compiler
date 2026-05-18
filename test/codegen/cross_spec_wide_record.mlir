// RUN: %ecoc %s -emit=mlir-llvm -enable-unboxed-agg 2>&1 | %FileCheck %s
//
// Phase 3.3 (customMaxFields widening): a six-field record flows
// through cross-spec. Pre-widening this would have been rejected at
// the front-end (the record cap shares the customMaxFields gate); at
// the new cap of 8 the record stays as a record-shaped LogicalType
// and reaches the worker. All fields are primitive so the Direct
// LLVM struct-return path applies.

module {
  func.func @sum_six(%r: !eco.value) -> i64
      attributes {
          eco.logical_param_types = ["record:6:i:i:i:i:i:i"],
          eco.logical_result_types = ["i64"]
      } {
    %a = eco.project.record %r[0] : !eco.value -> i64
    %b = eco.project.record %r[1] : !eco.value -> i64
    %c = eco.project.record %r[2] : !eco.value -> i64
    %d = eco.project.record %r[3] : !eco.value -> i64
    %e = eco.project.record %r[4] : !eco.value -> i64
    %f = eco.project.record %r[5] : !eco.value -> i64
    %ab = arith.addi %a, %b : i64
    %cd = arith.addi %c, %d : i64
    %ef = arith.addi %e, %f : i64
    %abcd = arith.addi %ab, %cd : i64
    %sum = arith.addi %abcd, %ef : i64
    return %sum : i64
  }
}

// Wide-record worker exists with all 6 fields scalar-flattened to
// individual i64 params (post EcoFlattenAggBoundary). The wrapper
// keeps the original boxed ABI:
// CHECK-DAG: llvm.func @sum_six$unboxed
// CHECK-DAG: llvm.func @sum_six(
