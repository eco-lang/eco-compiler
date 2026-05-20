// RUN: %ecoc %s -emit=mlir-llvm -enable-unboxed-agg 2>&1 | %FileCheck %s
//
// Regression for Issue 3 from plans/cross-spec-bridgeoperands-regressions.md.
// Before the Phase 1.5 stopgap, rewriteConstructToMake propagated
// aggregate-typed field operands verbatim into the new make.*'s result
// element list, producing a nested aggregate type that downstream
// project/lowering paths couldn't decode. The stopgap boxes any
// aggregate-typed field via eco.to_heap before recording its type so
// the make.* result element list stays flat.
//
// An eligible call's aggregate result (@make_t -> !eco.tuple2<i64,i64>)
// flows into a construct.record field operand inside another eligible
// function's body. rewriteConstructToMake derives the new make.record's
// result element types directly from the operand SSA types — if any
// operand is itself aggregate, the resulting RecordType is nested
// (e.g. !eco.record<!eco.tuple2<i64,i64>, !eco.value>). RS4GC asserts
// "support for FCA unimplemented" on the nested FCA containing a
// ptr addrspace(1).
//
// The fix (Phase 1.5 stopgap) boxes any aggregate field operand via
// eco.to_heap before recording its type, keeping the make.* result
// element types flat.

module {
  // Promoted to return !eco.tuple2<i64, i64>.
  func.func @make_t() -> !eco.value
      attributes {
          eco.logical_param_types  = [],
          eco.logical_result_types = ["tuple2:i:i"]
      } {
    %a = arith.constant 10 : i64
    %b = arith.constant 20 : i64
    %t = eco.construct.tuple2 %a, %b {unboxed_bitmap = 5}
       : i64, i64 -> !eco.value
    return %t : !eco.value
  }

  // Promoted to return !eco.record<value, value>. Body calls @make_t
  // and stuffs the result into a record field — the trigger.
  func.func @make_rec() -> !eco.value
      attributes {
          eco.logical_param_types  = [],
          eco.logical_result_types = ["record:2:v:v"]
      } {
    %t   = call @make_t() : () -> !eco.value
    %nil = eco.constant Nil : !eco.value
    %r   = eco.construct.record(%t, %nil) {field_count = 2, unboxed_bitmap = 0}
         : (!eco.value, !eco.value) -> !eco.value
    return %r : !eco.value
  }
}

// Both workers exist.
// CHECK: llvm.func @make_t$unboxed
// CHECK: llvm.func @make_rec$unboxed

// No nested aggregate types appear in the lowered IR — the inner
// tuple is boxed into !eco.value before the outer record's field slot.
// CHECK-NOT: !eco.record<!eco.tuple2
// CHECK-NOT: !eco.record<!eco.record
// CHECK-NOT: !llvm.struct<(struct<
