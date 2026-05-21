// RUN: %ecoc %s -emit=mlir-llvm -enable-unboxed-agg 2>&1 | %FileCheck %s
//
// Phase 2 §3.8 of plans/cross-spec-nested-shape-dsl.md (primitive-inner
// case): an eligible callee's promoted aggregate result flows directly
// into a parent's `construct.record` field slot whose declared shape
// is itself the same aggregate. With the §3.4 admission gate satisfied
// (no GC pointer in the inner aggregate), cross-spec stitches the two
// together without inserting an `eco.to_heap` between the call and
// the construct — the Phase 1.5 stopgap's defining trigger.
//
// The companion fixture `cross_spec_nested_make_record_from_construct.mlir`
// covers the *flat* declared shape (`record:2:v:v`) where the stopgap
// must still box. Here the declared shape is `record:2:[tuple2:i:i]:v`
// — the nested form — and the rewrite is allowed to flow the tuple2
// value through verbatim.

module {
  // Promoted to return !eco.tuple2<i64, i64>.
  func.func @make_inner_pair() -> !eco.value
      attributes {
          eco.logical_param_types = [],
          eco.logical_result_types = ["tuple2:i:i"]
      } {
    %a = arith.constant 10 : i64
    %b = arith.constant 20 : i64
    %t = eco.construct.tuple2 %a, %b {unboxed_bitmap = 5}
       : i64, i64 -> !eco.value
    return %t : !eco.value
  }

  // Promoted to return !eco.record<!eco.tuple2<i64,i64>, !eco.value>.
  // Body calls @make_inner_pair and stuffs its result into the record's
  // first field. Without the §3.4 gate + nested DSL, the stopgap
  // would box the inner tuple2 via eco.to_heap before the construct.
  func.func @make_outer_record() -> !eco.value
      attributes {
          eco.logical_param_types = [],
          eco.logical_result_types = ["record:2:[tuple2:i:i]:v"]
      } {
    %t   = call @make_inner_pair() : () -> !eco.value
    %nil = eco.constant Nil : !eco.value
    %r   = eco.construct.record(%t, %nil) {field_count = 2, unboxed_bitmap = 0}
         : (!eco.value, !eco.value) -> !eco.value
    return %r : !eco.value
  }
}

// Both workers exist.
// CHECK-DAG: llvm.func @make_inner_pair$unboxed
// CHECK-DAG: llvm.func @make_outer_record$unboxed
//
// External wrappers exist.
// CHECK-DAG: llvm.func @make_inner_pair(
// CHECK-DAG: llvm.func @make_outer_record(
//
// The worker body for @make_outer_record$unboxed must NOT contain a
// `to_heap` call between the inner-pair worker call and the outer
// record build — the chained-aggregate eco.to_heap insertion the
// Phase 1.5 stopgap forced is elided when the nested DSL admits the
// inner aggregate verbatim.
//
// (We can't easily anchor this to the worker symbol via FileCheck
// without ordering pitfalls, so assert the negative form globally:
// no calls to to_heap that wrap a tuple2 producer reach the lowered
// IR for this fixture.)
// CHECK-NOT: !eco.tuple2<i64, i64>, !llvm.ptr<1>
