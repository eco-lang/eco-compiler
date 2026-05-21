// RUN: %ecoc %s -emit=mlir-llvm -enable-unboxed-agg 2>&1 | %FileCheck %s
//
// Phase 2 §3.4 of plans/cross-spec-nested-shape-dsl.md (GC-pointer-inner
// demotion): the same chained-aggregate pattern as
// `cross_spec_nested_record_primitive_inner.mlir`, but the inner
// aggregate carries a `!eco.value` element. RS4GC can't lower a nested
// FCA holding a `ptr addrspace(1)` ("support for FCA unimplemented"),
// so the §3.4 admission gate must refuse the nesting and demote the
// outer slot to a flat shape — falling back to the Phase 1 boxed form
// at that position.
//
// Verification: no nested aggregate carrying a ptr addrspace(1) lands
// in the lowered IR. The outer record's first field stays !eco.value
// at the worker boundary.

module {
  // Inner result is tuple2:i:v — primitive + boxed. Not GC-pointer-free,
  // so when used as a nested element it must demote.
  func.func @make_inner_with_value() -> !eco.value
      attributes {
          eco.logical_param_types = [],
          eco.logical_result_types = ["tuple2:i:v"]
      } {
    %a   = arith.constant 7 : i64
    %nil = eco.constant Nil : !eco.value
    %t   = eco.construct.tuple2 %a, %nil {unboxed_bitmap = 1}
         : i64, !eco.value -> !eco.value
    return %t : !eco.value
  }

  // Declared with a nested inner shape that contains a `!eco.value`.
  // The §3.4 gate must demote the outer slot's first element back to
  // `value`, falling out to a flat record:2:v:v shape.
  func.func @make_outer_demoted() -> !eco.value
      attributes {
          eco.logical_param_types = [],
          eco.logical_result_types = ["record:2:[tuple2:i:v]:v"]
      } {
    %t   = call @make_inner_with_value() : () -> !eco.value
    %nil = eco.constant Nil : !eco.value
    %r   = eco.construct.record(%t, %nil) {field_count = 2, unboxed_bitmap = 0}
         : (!eco.value, !eco.value) -> !eco.value
    return %r : !eco.value
  }
}

// The inner function still promotes — its result shape (`tuple2:i:v`)
// is a *top-level* aggregate with a `!eco.value` element, which is the
// existing Sret path and not gated by §3.4 (the gate only rejects
// `!eco.value` strictly inside a *nested* element).
// CHECK-DAG: llvm.func @make_inner_with_value$unboxed
// CHECK-DAG: llvm.func @make_inner_with_value(
//
// The outer function's external wrapper still exists; the worker may
// or may not be emitted depending on whether any *other* slot remains
// aggregate after demotion — here the second slot is `v` (Boxed), so
// every slot collapses and the function falls back to the non-promoted
// path entirely. Either way, no nested FCA with ptr addrspace(1)
// strictly inside must reach RS4GC.
// CHECK-DAG: llvm.func @make_outer_demoted(
//
// Critical structural guarantee: no LLVM struct literal that contains
// an inner struct holding a ptr addrspace(1) appears anywhere in the
// lowered IR. This is the exact shape RS4GC rejects.
// CHECK-NOT: !llvm.struct<(struct<{{.*}}ptr<1>
// CHECK-NOT: !llvm.struct<(struct<{{.*}}ptr addrspace(1)
