// RUN: %ecoc %s -emit=mlir-llvm -enable-unboxed-agg 2>&1 | %FileCheck %s
//
// Regression for Issue 1 from plans/cross-spec-bridgeoperands-regressions.md.
// Before the fix, bridgeOperands indexed paramShapes[i] against
// operands[i] without skipping the leading sret slots, producing
// `eco.from_heap(!llvm.ptr) → !eco.tuple2<...>` and a verifier error.
// The fix threads `argOffset = sretSlotVals.size()` through the lambda.
//
// Two functions whose worker signatures simultaneously carry an Sret
// outparam (return is a record containing !eco.value) AND an aggregate
// parameter (record of two i64s). @outer's body calls @inner, so
// cross-spec redirects the call inside @outer$unboxed. The redirected
// call's operands array layout is [sret_slot (!llvm.ptr), aggregate_param].
// bridgeOperands iterates paramShapes against operands starting from
// index 0; pre-fix it tries to from_heap the sret slot pointer, which
// the eco.from_heap verifier rejects with:
//   error: 'eco.from_heap' op operand #0 must be eco.value,
//          but got '!llvm.ptr'

module {
  func.func @inner(%p: !eco.value) -> !eco.value
      attributes {
          eco.logical_param_types  = ["record:2:i:i"],
          eco.logical_result_types = ["record:2:i:v"]
      } {
    %x = eco.project.record %p[0] : !eco.value -> i64
    %nil = eco.constant Nil : !eco.value
    %r = eco.construct.record(%x, %nil) {field_count = 2, unboxed_bitmap = 1}
       : (i64, !eco.value) -> !eco.value
    return %r : !eco.value
  }

  func.func @outer(%p: !eco.value) -> !eco.value
      attributes {
          eco.logical_param_types  = ["record:2:i:i"],
          eco.logical_result_types = ["record:2:i:v"]
      } {
    %r = call @inner(%p) : (!eco.value) -> !eco.value
    return %r : !eco.value
  }
}

// Both workers exist in the lowered IR.
// CHECK: llvm.func @inner$unboxed
// CHECK: llvm.func @outer$unboxed

// And no eco.from_heap survives with an !llvm.ptr operand — the
// bridgeOperands fix must skip the leading sret slot.
// CHECK-NOT: eco.from_heap{{.*}}!llvm.ptr
