// RUN: %ecoc %s -emit=mlir-eco 2>&1 | %FileCheck %s
//
// CGEN_094 (plans/staging-from-lambda-sets.md, A.4): EcoPAPSimplify's chain fusion does not
// fuse a following extend into a generic extend carrying `_stage_hint = h` past h newargs. The
// hinted extend's closure takes h arguments in its first stage, so the fused extend would be an
// over-application, which cannot take the guarded `sat[N]` edge; the two extends can each take it.
// The closure is a parameter in every function, so create+extend fusion cannot apply.
//
// @hinted: hint 1 on a one-newarg extend: the following extend is not fused (two papExtends).
// @unhinted: the control, today's behaviour: one fused papExtend of two newargs.
// @within_hint: hint 3 on a one-newarg extend, then a two-newarg extend: they fuse (three
// newargs, within the hint), and the fused extend keeps `_stage_hint = 3`.
// @past_hint: hint 2 on a one-newarg extend, then a two-newarg extend: three newargs would pass
// the hint, so they are not fused.

module {
  func.func @hinted(%f: !eco.value, %a: i64, %b: i64) -> !eco.value {
    %r1 = "eco.papExtend"(%f, %a) {_stage_hint = 1 : i64, _call_kind = "segmentation_unknown", slot_kinds = array<i8: 1>} : (!eco.value, i64) -> !eco.value
    %r2 = "eco.papExtend"(%r1, %b) {_call_kind = "segmentation_unknown", slot_kinds = array<i8: 1>} : (!eco.value, i64) -> !eco.value
    eco.return %r2 : !eco.value
  }

  func.func @unhinted(%f: !eco.value, %a: i64, %b: i64) -> !eco.value {
    %r1 = "eco.papExtend"(%f, %a) {_call_kind = "segmentation_unknown", slot_kinds = array<i8: 1>} : (!eco.value, i64) -> !eco.value
    %r2 = "eco.papExtend"(%r1, %b) {_call_kind = "segmentation_unknown", slot_kinds = array<i8: 1>} : (!eco.value, i64) -> !eco.value
    eco.return %r2 : !eco.value
  }

  func.func @within_hint(%f: !eco.value, %a: i64, %b: i64, %c: i64) -> !eco.value {
    %r1 = "eco.papExtend"(%f, %a) {_stage_hint = 3 : i64, _call_kind = "generic_apply", slot_kinds = array<i8: 1>} : (!eco.value, i64) -> !eco.value
    %r2 = "eco.papExtend"(%r1, %b, %c) {_call_kind = "generic_apply", slot_kinds = array<i8: 1, 1>} : (!eco.value, i64, i64) -> !eco.value
    eco.return %r2 : !eco.value
  }

  func.func @past_hint(%f: !eco.value, %a: i64, %b: i64, %c: i64) -> !eco.value {
    %r1 = "eco.papExtend"(%f, %a) {_stage_hint = 2 : i64, _call_kind = "generic_apply", slot_kinds = array<i8: 1>} : (!eco.value, i64) -> !eco.value
    %r2 = "eco.papExtend"(%r1, %b, %c) {_call_kind = "generic_apply", slot_kinds = array<i8: 1, 1>} : (!eco.value, i64, i64) -> !eco.value
    eco.return %r2 : !eco.value
  }
}

// CHECK-LABEL: func.func @hinted
// CHECK: "eco.papExtend"(%arg0, %arg1)
// CHECK-SAME: _stage_hint = 1
// CHECK-NEXT: "eco.papExtend"(%0, %arg2)
// CHECK-NEXT: eco.return %1

// CHECK-LABEL: func.func @unhinted
// CHECK: "eco.papExtend"(%arg0, %arg1, %arg2)
// CHECK-NEXT: eco.return %0

// CHECK-LABEL: func.func @within_hint
// CHECK: "eco.papExtend"(%arg0, %arg1, %arg2, %arg3)
// CHECK-SAME: _stage_hint = 3
// CHECK-NEXT: eco.return %0

// CHECK-LABEL: func.func @past_hint
// CHECK: "eco.papExtend"(%arg0, %arg1)
// CHECK-SAME: _stage_hint = 2
// CHECK-NEXT: "eco.papExtend"(%0, %arg2, %arg3)
// CHECK-NEXT: eco.return %1
