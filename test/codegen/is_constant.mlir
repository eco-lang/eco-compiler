// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// eco.is_constant (CGEN_087): true exactly for an embedded constant (ptr_ind set: Empty, True,
// False, a null-cons word), false for a heap object. The nullable representation of a
// Maybe-shaped user type tests its nullary constructor with it (REP_CONSTANT_003).

module {
  func.func @main() -> i64 {
    %empty = eco.constant Empty : !eco.value
    %true = eco.constant True : !eco.value
    %nc = eco.constant.null_cons 3 : !eco.value
    %i = arith.constant 7 : i64
    %boxed = eco.box %i : i64 -> !eco.value
    %heap = eco.construct.custom(%boxed) <{slot_kinds = array<i8: 0>, tag = 0 : i64, size = 1 : i64}> : (!eco.value) -> !eco.value

    %a = eco.is_constant %empty : !eco.value -> i1
    %b = eco.is_constant %true : !eco.value -> i1
    %c = eco.is_constant %nc : !eco.value -> i1
    %d = eco.is_constant %heap : !eco.value -> i1
    %ai = arith.extui %a : i1 to i64
    %bi = arith.extui %b : i1 to i64
    %ci = arith.extui %c : i1 to i64
    %di = arith.extui %d : i1 to i64
    eco.dbg %ai : i64
    // CHECK: 1
    eco.dbg %bi : i64
    // CHECK: 1
    eco.dbg %ci : i64
    // CHECK: 1
    eco.dbg %di : i64
    // CHECK: 0
    %r = arith.constant 0 : i64
    return %r : i64
  }
}
