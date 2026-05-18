// RUN: %ecoc %s -emit=mlir-llvm -enable-unboxed-agg 2>&1 | %FileCheck %s
//
// Phase 3.1 #4 (result-side unboxing) for records: an all-primitive
// 2-field record returned from a function gets specialised into a
// worker with `!eco.record<i64, f64>` result (flattened to multi-
// return `(i64, f64)` by Phase 3.1 #3) plus a wrapper that boxes via
// `eco.to_heap` with the matching unboxed_bitmap.

module {
  func.func @build_rec(%n: i64, %x: f64) -> !eco.value
      attributes {
          eco.logical_param_types = ["i64", "f64"],
          eco.logical_result_types = ["record:2:i:f"]
      } {
    %r = eco.construct.record(%n, %x) {field_count = 2, unboxed_bitmap = 0}
       : (i64, f64) -> !eco.value
    return %r : !eco.value
  }
}

// CHECK: llvm.func @build_rec$unboxed
// CHECK-SAME: -> !llvm.struct<(i64, f64)>
//
// CHECK: llvm.func @build_rec(
// CHECK: llvm.call @eco_alloc_record
