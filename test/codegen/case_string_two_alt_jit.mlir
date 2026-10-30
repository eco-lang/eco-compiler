// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// A string `eco.case` with two alternatives ("hello" and the default) whose alternatives yield, not
// nested in scf, is declined by CaseStringToScfIfChainPattern (it wants an scf parent). Until
// 2026-10-30 CaseToScfIfPattern then took it and tested the scrutinee's CONSTRUCTOR TAG against
// tags[1] instead of comparing strings, so "hello" and "world" took the same branch; it now declines
// string cases and EcoToLLVM lowers this one with string compares. The front end never emits a
// two-alternative string case (a one-edge decision becomes a Chain, so every `str` fan-out has at
// least three alternatives), so only hand-written MLIR reaches it. @classify3, a three-alternative
// case, is the control.
//
// CHECK: [eco.dbg] 1
// CHECK: [eco.dbg] 2
// CHECK: [eco.dbg] 3
// CHECK: [eco.dbg] 10
// CHECK: [eco.dbg] 20

module {
  func.func @classify3(%s: !eco.value) -> i64 {
    %r = eco.case %s : !eco.value [0, 1, 2] -> (i64) {case_kind = "str", string_patterns = ["hello", "bye"]} {
      %a = arith.constant 1 : i64
      eco.yield %a : i64
    }, {
      %b = arith.constant 2 : i64
      eco.yield %b : i64
    }, {
      %c = arith.constant 3 : i64
      eco.yield %c : i64
    }
    return %r : i64
  }

  func.func @classify2(%s: !eco.value) -> i64 {
    %r = eco.case %s : !eco.value [0, 1] -> (i64) {case_kind = "str", string_patterns = ["hello"]} {
      %a = arith.constant 10 : i64
      eco.yield %a : i64
    }, {
      %b = arith.constant 20 : i64
      eco.yield %b : i64
    }
    return %r : i64
  }

  func.func @main() -> i64 {
    %h = eco.string_literal "hello" : !eco.value
    %y = eco.string_literal "bye" : !eco.value
    %w = eco.string_literal "world" : !eco.value
    %c1 = func.call @classify3(%h) : (!eco.value) -> i64
    eco.dbg %c1 : i64
    %c2 = func.call @classify3(%y) : (!eco.value) -> i64
    eco.dbg %c2 : i64
    %c3 = func.call @classify3(%w) : (!eco.value) -> i64
    eco.dbg %c3 : i64
    %r1 = func.call @classify2(%h) : (!eco.value) -> i64
    eco.dbg %r1 : i64
    %r2 = func.call @classify2(%w) : (!eco.value) -> i64
    eco.dbg %r2 : i64
    %z = arith.constant 0 : i64
    return %z : i64
  }
}
