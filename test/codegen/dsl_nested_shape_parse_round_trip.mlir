// RUN: %ecoc %s -emit=mlir-llvm -enable-unboxed-agg 2>&1 | %FileCheck %s
//
// Phase 2 §3.1 + §3.2 of plans/cross-spec-nested-shape-dsl.md: cross-spec's
// logical-types DSL accepts bracketed sub-shapes (e.g.
// `record:2:[tuple2:i:i]:v`), and a hand-written fixture declaring such a
// shape parses cleanly and promotes the slot to a nested aggregate
// worker signature. The bracket form is the encoding the front-end can
// adopt later; the parser change carries the surface today.
//
// Inner shape is GC-pointer-free (i64, i64), so the §3.4 admission gate
// admits the nesting. Outer shape carries a `!eco.value` element, so
// the outer slot routes through the Sret ABI — the slot struct type
// then has a nested LLVM struct at field 0 and a ptr addrspace(1) at
// field 1.

module {
  // Same-spec callee whose result feeds the outer record's nested slot.
  func.func @produce_inner() -> !eco.value
      attributes {
          eco.logical_param_types = [],
          eco.logical_result_types = ["tuple2:i:i"]
      } {
    %a = arith.constant 1 : i64
    %b = arith.constant 2 : i64
    %t = eco.construct.tuple2 %a, %b : i64, i64 -> !eco.value
    return %t : !eco.value
  }

  // Bracket DSL: field 0 is itself a tuple2:i:i (nested), field 1 is
  // a boxed value. Cross-spec's parser must accept this without
  // demoting the slot to Boxed.
  func.func @produce_nested() -> !eco.value
      attributes {
          eco.logical_param_types = [],
          eco.logical_result_types = ["record:2:[tuple2:i:i]:v"]
      } {
    %t = call @produce_inner() : () -> !eco.value
    %nil = eco.constant Empty : !eco.value
    %r = eco.construct.record(%t, %nil) {field_count = 2, unboxed_bitmap = 0}
       : (!eco.value, !eco.value) -> !eco.value
    return %r : !eco.value
  }
}

// Both workers exist — confirming cross-spec admitted the nested DSL.
// CHECK-DAG: llvm.func @produce_inner$unboxed
// CHECK-DAG: llvm.func @produce_nested$unboxed
//
// External wrappers exist (the original ABI keeps working):
// CHECK-DAG: llvm.func @produce_inner(
// CHECK-DAG: llvm.func @produce_nested(
