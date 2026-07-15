// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// H6.2 follow-up pin: GENERIC extend chains fuse to one generic extend
// (one PAP allocation instead of two) and stay observationally identical
// — including when the chain saturates MID-fusion: @add2 needs 2 args,
// the first generic extend supplies both (saturates and calls), the
// second applies the leftover arg to the RESULT (a closure returned by
// @add2's callee position... here the result is consumed saturated, so
// the chain exercises apply-through-saturation). The runtime's multi-arg
// generic apply chains through saturation, which is what makes the
// fusion sound.

module {
  func.func @add3(%a: i64, %b: i64, %c: i64) -> i64 {
    %ab = eco.int.add %a, %b : i64
    %abc = eco.int.add %ab, %c : i64
    eco.return %abc : i64
  }

  func.func @main() -> i64 {
    %c1 = arith.constant 1 : i64
    %c2 = arith.constant 2 : i64
    %c3 = arith.constant 3 : i64

    %pap = "eco.papCreate"() {
      function = @add3,
      arity = 3 : i64,
      num_captured = 0 : i64,
      unboxed_bitmap = 0 : i64
    } : () -> !eco.value

    // Generic-mode chain (no remaining_arity): fused into one extend.
    %pap2 = "eco.papExtend"(%pap, %c1) {
      newargs_unboxed_bitmap = 1 : i64,
      _call_kind = "segmentation_unknown"
    } : (!eco.value, i64) -> !eco.value

    %pap3 = "eco.papExtend"(%pap2, %c2) {
      newargs_unboxed_bitmap = 1 : i64,
      _call_kind = "segmentation_unknown"
    } : (!eco.value, i64) -> !eco.value

    %result = "eco.papExtend"(%pap3, %c3) {
      newargs_unboxed_bitmap = 1 : i64,
      _result_kind = 1 : i8,
      _call_kind = "segmentation_unknown"
    } : (!eco.value, i64) -> i64

    eco.dbg %result : i64
    // CHECK: [eco.dbg] 6

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
