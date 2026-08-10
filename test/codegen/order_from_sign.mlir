// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Phase C (CGEN_075): the eco.*.cmp_order lowering picks its Order singleton
// with ONE gc-leaf `eco_order_from_sign` call instead of calling all three
// Eco_Runtime_getOrder* getters unconditionally.
//
// These producers all ESCAPE (returned, not cased), so EcoCompareCaseRewrite
// leaves them alone and the cmp_order lowering — the thing under test here —
// is what actually runs. `eco.get_tag` reads the Order ctor: LT=0, EQ=1, GT=2.

module {
  func.func private @tag_int(%a: i64, %b: i64) -> i64 {
    %o = eco.int.cmp_order %a, %b : i64
    %t = eco.get_tag %o : !eco.value -> i32
    %r = arith.extui %t : i32 to i64
    eco.return %r : i64
  }

  func.func private @tag_float(%a: f64, %b: f64) -> i64 {
    %o = eco.float.cmp_order %a, %b : f64
    %t = eco.get_tag %o : !eco.value -> i32
    %r = arith.extui %t : i32 to i64
    eco.return %r : i64
  }

  func.func private @tag_char(%a: i16, %b: i16) -> i64 {
    %o = eco.char.cmp_order %a, %b : i16
    %t = eco.get_tag %o : !eco.value -> i32
    %r = arith.extui %t : i32 to i64
    eco.return %r : i64
  }

  func.func private @tag_str(%a: !eco.value, %b: !eco.value) -> i64 {
    %o = eco.string.cmp_order %a, %b : !eco.value
    %t = eco.get_tag %o : !eco.value -> i32
    %r = arith.extui %t : i32 to i64
    eco.return %r : i64
  }

  func.func @main() -> i64 {
    %c0 = arith.constant 0 : i64
    %i1 = arith.constant 1 : i64
    %i2 = arith.constant 2 : i64

    // Int: LT=0, EQ=1, GT=2
    %a = func.call @tag_int(%i1, %i2) : (i64, i64) -> i64
    %ba = eco.box %a : i64 -> !eco.value
    eco.dbg %ba : !eco.value
    // CHECK: 0
    %b = func.call @tag_int(%i2, %i2) : (i64, i64) -> i64
    %bb = eco.box %b : i64 -> !eco.value
    eco.dbg %bb : !eco.value
    // CHECK: 1
    %c = func.call @tag_int(%i2, %i1) : (i64, i64) -> i64
    %bc = eco.box %c : i64 -> !eco.value
    eco.dbg %bc : !eco.value
    // CHECK: 2

    // Float, including NaN -> EQ (ordered predicates) and -0.0 == 0.0
    %f1 = arith.constant 1.0 : f64
    %f2 = arith.constant 2.0 : f64
    %nan = arith.constant 0x7FF8000000000000 : f64
    %nz = arith.constant -0.0 : f64
    %pz = arith.constant 0.0 : f64
    %d = func.call @tag_float(%f1, %f2) : (f64, f64) -> i64
    %bd = eco.box %d : i64 -> !eco.value
    eco.dbg %bd : !eco.value
    // CHECK: 0
    %e = func.call @tag_float(%f2, %f1) : (f64, f64) -> i64
    %be = eco.box %e : i64 -> !eco.value
    eco.dbg %be : !eco.value
    // CHECK: 2
    %f = func.call @tag_float(%nan, %f1) : (f64, f64) -> i64
    %bf = eco.box %f : i64 -> !eco.value
    eco.dbg %bf : !eco.value
    // CHECK: 1
    %g = func.call @tag_float(%nz, %pz) : (f64, f64) -> i64
    %bg = eco.box %g : i64 -> !eco.value
    eco.dbg %bg : !eco.value
    // CHECK: 1

    // Char at the u16 extremes: unsigned, so 0x0000 < 0xFFFF
    %clo = arith.constant 0 : i16
    %chi = arith.constant -1 : i16
    %h = func.call @tag_char(%clo, %chi) : (i16, i16) -> i64
    %bh = eco.box %h : i64 -> !eco.value
    eco.dbg %bh : !eco.value
    // CHECK: 0
    %i = func.call @tag_char(%chi, %clo) : (i16, i16) -> i64
    %bi = eco.box %i : i64 -> !eco.value
    eco.dbg %bi : !eco.value
    // CHECK: 2

    // String, including the Empty embedded constant ordering below non-empty
    %sa = eco.string_literal "apple" : !eco.value
    %sb = eco.string_literal "banana" : !eco.value
    %empty = eco.constant Empty : !eco.value
    %j = func.call @tag_str(%sa, %sb) : (!eco.value, !eco.value) -> i64
    %bj = eco.box %j : i64 -> !eco.value
    eco.dbg %bj : !eco.value
    // CHECK: 0
    %k = func.call @tag_str(%sb, %sa) : (!eco.value, !eco.value) -> i64
    %bk = eco.box %k : i64 -> !eco.value
    eco.dbg %bk : !eco.value
    // CHECK: 2
    %l = func.call @tag_str(%empty, %sa) : (!eco.value, !eco.value) -> i64
    %bl = eco.box %l : i64 -> !eco.value
    eco.dbg %bl : !eco.value
    // CHECK: 0
    %m = func.call @tag_str(%empty, %empty) : (!eco.value, !eco.value) -> i64
    %bm = eco.box %m : i64 -> !eco.value
    eco.dbg %bm : !eco.value
    // CHECK: 1

    return %c0 : i64
  }
}
