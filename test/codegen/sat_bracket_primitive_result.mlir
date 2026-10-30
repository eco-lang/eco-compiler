// RUN: %ecoc %s -emit=mlir-llvm 2>&1 | %FileCheck %s
//
// XFAIL: cpp-review-bugs.md "Primitive-result closure calls emit an unmatched __eco_sat_begin" -- not fixed yet (a missed optimisation, not wrong output)
//
// A saturating typed eco.papExtend with no `_fast_evaluator` is lowered by emitInlineClosureCall
// (EcoToLLVMClosures.cpp), which brackets the call with __eco_sat_begin / __eco_sat_end so the
// backend can turn it into a `$sat` fast-path call. For an Int / Float / Char result the
// primitive-result branch returns before emitting __eco_sat_end, so expandSatMarkers drops the
// unmatched begin: the call stays on the generic path (and keeps a dead inline resolve). Ordinary
// Elm reaches it, but the output does not change, so only the IR shows it. @caller_boxed, with a
// boxed result, is the control.
//
// CHECK-LABEL: llvm.func @caller_int(
// CHECK: llvm.call @__eco_sat_begin
// CHECK: llvm.call @__eco_sat_end
// CHECK-LABEL: llvm.func @caller_boxed(
// CHECK: llvm.call @__eco_sat_begin
// CHECK: llvm.call @__eco_sat_end

module {
  func.func @add(%a: i64, %b: i64) -> i64 {
    %r = eco.int.add %a, %b : i64
    eco.return %r : i64
  }
  func.func @wrap(%a: i64, %b: i64) -> !eco.value {
    %r = eco.int.add %a, %b : i64
    %v = eco.box %r : i64 -> !eco.value
    eco.return %v : !eco.value
  }
  func.func @caller_int(%pap: !eco.value, %y: i64) -> i64 {
    %r = "eco.papExtend"(%pap, %y) {remaining_arity = 1 : i64, slot_kinds = array<i8: 1>} : (!eco.value, i64) -> i64
    eco.return %r : i64
  }
  func.func @caller_boxed(%pap: !eco.value, %y: i64) -> !eco.value {
    %r = "eco.papExtend"(%pap, %y) {remaining_arity = 1 : i64, slot_kinds = array<i8: 1>} : (!eco.value, i64) -> !eco.value
    eco.return %r : !eco.value
  }
  func.func @main() -> i64 {
    %c1 = arith.constant 1 : i64
    %c2 = arith.constant 2 : i64
    %p = "eco.papCreate"(%c1) {function = @add, arity = 2 : i64, num_captured = 1 : i64, slot_kinds = array<i8: 1>} : (i64) -> !eco.value
    %r = func.call @caller_int(%p, %c2) : (!eco.value, i64) -> i64
    eco.dbg %r : i64
    %q = "eco.papCreate"(%c1) {function = @wrap, arity = 2 : i64, num_captured = 1 : i64, slot_kinds = array<i8: 1>} : (i64) -> !eco.value
    %s = func.call @caller_boxed(%q, %c2) : (!eco.value, i64) -> !eco.value
    eco.dbg %s : !eco.value
    %z = arith.constant 0 : i64
    return %z : i64
  }
}
