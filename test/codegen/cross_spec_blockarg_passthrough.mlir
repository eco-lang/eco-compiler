// RUN: %ecoc %s -emit=mlir-llvm -enable-unboxed-agg 2>&1 | %FileCheck %s
//
// Phase 3.1 #4 (relaxed result-side eligibility): a function that
// returns its aggregate-typed parameter directly must be eligible
// when the param and result shapes match. The fixpoint admits a
// BlockArgument producer at a return position iff the corresponding
// param is being promoted to the same aggregate shape.

module {
  func.func @passthrough(%t: !eco.value) -> !eco.value
      attributes {
          eco.logical_param_types = ["tuple2:i:i"],
          eco.logical_result_types = ["tuple2:i:i"]
      } {
    return %t : !eco.value
  }
}

// Worker exists with both sides flattened to scalar (i64, i64):
// CHECK: llvm.func @passthrough$unboxed
// CHECK-SAME: i64
// CHECK-SAME: i64
// CHECK-SAME: -> !llvm.struct<(i64, i64)>
//
// Wrapper exists, unboxes via eco_resolve_hptr, reboxes via eco_alloc_tuple2:
// CHECK: llvm.func @passthrough(
// CHECK: llvm.call @eco_resolve_hptr
// CHECK: llvm.call @eco_alloc_tuple2
