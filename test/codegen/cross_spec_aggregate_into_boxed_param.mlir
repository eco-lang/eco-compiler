// RUN: %ecoc %s -emit=mlir-llvm -enable-unboxed-agg 2>&1 | %FileCheck %s
//
// Regression for Issue 2 from plans/cross-spec-bridgeoperands-regressions.md.
// Before the fix, bridgeOperands handled only the value→aggregate
// direction (eco.from_heap). When an aggregate operand flowed into a
// callee whose paramShape stayed Boxed, no bridging was inserted and
// the resulting func.call had a type mismatch. The fix adds the
// aggregate→!eco.value branch via eco.to_heap.
//
// @F is eligible: param 0 is an aggregate, param 1 stays boxed because
// param 1's only use is a call to the non-eligible @opaque consumer.
// @W is eligible: it passes its aggregate param to @F's *boxed* param 1.
// The eligibility check `allUsesAreProjectionsOrCallsToEligible` accepts
// the use because @F is in the eligible set — it does NOT verify the
// shape matches @F's param 1 specifically.
// Cross-spec then promotes @W's param. Inside @W$unboxed's body, the
// call to @F$unboxed passes an aggregate-typed block argument at
// position 1, but @F$unboxed's param 1 is !eco.value. bridgeOperands
// only handles value->aggregate (eco.from_heap); the aggregate->value
// direction (eco.to_heap) is missing, leaving a func.call with a type
// mismatch:
//   error: 'func.call' op operand type mismatch:
//          expected operand type '!eco.value',
//          but provided '!eco.record<!eco.value, !eco.value>'
//          for operand number 1

module {
  // Non-eligible: keeps @F's param 1 from being promoted.
  func.func @opaque(%x: !eco.value) -> !eco.value {
    return %x : !eco.value
  }

  // Param 0 is record-aggregate-shaped (eligible via projection use).
  // Param 1 is logically "value" — stays boxed because the only use is
  // a call to non-eligible @opaque.
  func.func @F(%agg: !eco.value, %boxed: !eco.value) -> !eco.value
      attributes {
          eco.logical_param_types  = ["record:2:i:i", "value"],
          eco.logical_result_types = ["value"]
      } {
    %x = eco.project.record %agg[0] : !eco.value -> i64
    %r = call @opaque(%boxed) : (!eco.value) -> !eco.value
    return %r : !eco.value
  }

  // @W's param 0 is record:2:v:v. Its only use is being passed to @F
  // at position 1 (a Boxed slot on the callee). Eligibility accepts
  // because @F is in the eligible set — exactly the gap.
  func.func @W(%v_rec: !eco.value, %i_rec: !eco.value) -> !eco.value
      attributes {
          eco.logical_param_types  = ["record:2:v:v", "record:2:i:i"],
          eco.logical_result_types = ["value"]
      } {
    %r = call @F(%i_rec, %v_rec) : (!eco.value, !eco.value) -> !eco.value
    return %r : !eco.value
  }
}

// All three functions survive lowering — no verifier error firing.
// CHECK: llvm.func @opaque(
// CHECK: llvm.func @F$unboxed

// Inside @W$unboxed, the aggregate operand at position 1 of the
// @F$unboxed call is boxed via eco_alloc_record before the call.
// CHECK:      llvm.func @W$unboxed
// CHECK:      llvm.call @eco_alloc_record
// CHECK:      llvm.call @F$unboxed
