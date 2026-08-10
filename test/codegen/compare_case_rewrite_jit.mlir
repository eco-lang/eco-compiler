// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Behavior pins for EcoCompareCaseRewrite: the rewritten form must select the
// same branch the Order round-trip would have. Each helper returns 1/2/3 for
// LT/EQ/GT so the selected branch is directly observable.
//
// The Float cases are the load-bearing ones: the rewrite emits ORDERED lt/gt
// with EQ as the final else, so NaN (which fails both) routes to EQ — matching
// emitOrderSelect's OLT/OGT shape. An OEQ-based second test would send NaN to
// GT instead.

module {
  func.func private @ord_int(%a: i64, %b: i64) -> i64 {
    %o = eco.int.cmp_order %a, %b : i64
    %r = eco.case %o : !eco.value [0, 1, 2] -> (i64) {case_kind = "ctor"} {
      %c1 = arith.constant 1 : i64
      eco.yield %c1 : i64
    }, {
      %c2 = arith.constant 2 : i64
      eco.yield %c2 : i64
    }, {
      %c3 = arith.constant 3 : i64
      eco.yield %c3 : i64
    }
    eco.return %r : i64
  }

  func.func private @ord_float(%a: f64, %b: f64) -> i64 {
    %o = eco.float.cmp_order %a, %b : f64
    %r = eco.case %o : !eco.value [0, 1, 2] -> (i64) {case_kind = "ctor"} {
      %c1 = arith.constant 1 : i64
      eco.yield %c1 : i64
    }, {
      %c2 = arith.constant 2 : i64
      eco.yield %c2 : i64
    }, {
      %c3 = arith.constant 3 : i64
      eco.yield %c3 : i64
    }
    eco.return %r : i64
  }

  func.func private @ord_char(%a: i16, %b: i16) -> i64 {
    %o = eco.char.cmp_order %a, %b : i16
    %r = eco.case %o : !eco.value [0, 1, 2] -> (i64) {case_kind = "ctor"} {
      %c1 = arith.constant 1 : i64
      eco.yield %c1 : i64
    }, {
      %c2 = arith.constant 2 : i64
      eco.yield %c2 : i64
    }, {
      %c3 = arith.constant 3 : i64
      eco.yield %c3 : i64
    }
    eco.return %r : i64
  }

  func.func private @ord_str(%a: !eco.value, %b: !eco.value) -> i64 {
    %o = eco.string.cmp_order %a, %b : !eco.value
    %r = eco.case %o : !eco.value [0, 1, 2] -> (i64) {case_kind = "ctor"} {
      %c1 = arith.constant 1 : i64
      eco.yield %c1 : i64
    }, {
      %c2 = arith.constant 2 : i64
      eco.yield %c2 : i64
    }, {
      %c3 = arith.constant 3 : i64
      eco.yield %c3 : i64
    }
    eco.return %r : i64
  }

  func.func @main() -> i64 {
    %c0 = arith.constant 0 : i64

    // --- Int: LT / EQ / GT ---
    %i1 = arith.constant 1 : i64
    %i2 = arith.constant 2 : i64
    %r1 = func.call @ord_int(%i1, %i2) : (i64, i64) -> i64
    %br1 = eco.box %r1 : i64 -> !eco.value
    eco.dbg %br1 : !eco.value
    // CHECK: 1
    %r2 = func.call @ord_int(%i2, %i2) : (i64, i64) -> i64
    %br2 = eco.box %r2 : i64 -> !eco.value
    eco.dbg %br2 : !eco.value
    // CHECK: 2
    %r3 = func.call @ord_int(%i2, %i1) : (i64, i64) -> i64
    %br3 = eco.box %r3 : i64 -> !eco.value
    eco.dbg %br3 : !eco.value
    // CHECK: 3

    // --- Float: LT / GT ---
    %f1 = arith.constant 1.0 : f64
    %f2 = arith.constant 2.0 : f64
    %r4 = func.call @ord_float(%f1, %f2) : (f64, f64) -> i64
    %br4 = eco.box %r4 : i64 -> !eco.value
    eco.dbg %br4 : !eco.value
    // CHECK: 1
    %r5 = func.call @ord_float(%f2, %f1) : (f64, f64) -> i64
    %br5 = eco.box %r5 : i64 -> !eco.value
    eco.dbg %br5 : !eco.value
    // CHECK: 3

    // --- Float: -0.0 vs 0.0 is EQ (ordered compare, not a bit compare) ---
    %fnz = arith.constant -0.0 : f64
    %fpz = arith.constant 0.0 : f64
    %r6 = func.call @ord_float(%fnz, %fpz) : (f64, f64) -> i64
    %br6 = eco.box %r6 : i64 -> !eco.value
    eco.dbg %br6 : !eco.value
    // CHECK: 2

    // --- Float NaN: each side and both -> EQ (fails both ordered tests) ---
    %nan = arith.constant 0x7FF8000000000000 : f64
    %r7 = func.call @ord_float(%nan, %f1) : (f64, f64) -> i64
    %br7 = eco.box %r7 : i64 -> !eco.value
    eco.dbg %br7 : !eco.value
    // CHECK: 2
    %r8 = func.call @ord_float(%f1, %nan) : (f64, f64) -> i64
    %br8 = eco.box %r8 : i64 -> !eco.value
    eco.dbg %br8 : !eco.value
    // CHECK: 2
    %r9 = func.call @ord_float(%nan, %nan) : (f64, f64) -> i64
    %br9 = eco.box %r9 : i64 -> !eco.value
    eco.dbg %br9 : !eco.value
    // CHECK: 2

    // --- Char at the u16 extremes: 0x0000 vs 0xFFFF must compare UNSIGNED,
    // so 0x0000 < 0xFFFF (a signed compare would invert this).
    %clo = arith.constant 0 : i16
    %chi = arith.constant -1 : i16
    %r10 = func.call @ord_char(%clo, %chi) : (i16, i16) -> i64
    %br10 = eco.box %r10 : i64 -> !eco.value
    eco.dbg %br10 : !eco.value
    // CHECK: 1
    %r11 = func.call @ord_char(%chi, %clo) : (i16, i16) -> i64
    %br11 = eco.box %r11 : i64 -> !eco.value
    eco.dbg %br11 : !eco.value
    // CHECK: 3
    %r12 = func.call @ord_char(%chi, %chi) : (i16, i16) -> i64
    %br12 = eco.box %r12 : i64 -> !eco.value
    eco.dbg %br12 : !eco.value
    // CHECK: 2

    // --- String: LT / EQ / GT, plus the Empty embedded constant ordering
    // below every non-empty string.
    %sa = eco.string_literal "apple" : !eco.value
    %sb = eco.string_literal "banana" : !eco.value
    %sa2 = eco.string_literal "apple" : !eco.value
    %r13 = func.call @ord_str(%sa, %sb) : (!eco.value, !eco.value) -> i64
    %br13 = eco.box %r13 : i64 -> !eco.value
    eco.dbg %br13 : !eco.value
    // CHECK: 1
    %r14 = func.call @ord_str(%sb, %sa) : (!eco.value, !eco.value) -> i64
    %br14 = eco.box %r14 : i64 -> !eco.value
    eco.dbg %br14 : !eco.value
    // CHECK: 3
    %r15 = func.call @ord_str(%sa, %sa2) : (!eco.value, !eco.value) -> i64
    %br15 = eco.box %r15 : i64 -> !eco.value
    eco.dbg %br15 : !eco.value
    // CHECK: 2

    %empty = eco.constant Empty : !eco.value
    %r16 = func.call @ord_str(%empty, %sa) : (!eco.value, !eco.value) -> i64
    %br16 = eco.box %r16 : i64 -> !eco.value
    eco.dbg %br16 : !eco.value
    // CHECK: 1
    %r17 = func.call @ord_str(%sa, %empty) : (!eco.value, !eco.value) -> i64
    %br17 = eco.box %r17 : i64 -> !eco.value
    eco.dbg %br17 : !eco.value
    // CHECK: 3
    %r18 = func.call @ord_str(%empty, %empty) : (!eco.value, !eco.value) -> i64
    %br18 = eco.box %r18 : i64 -> !eco.value
    eco.dbg %br18 : !eco.value
    // CHECK: 2

    return %c0 : i64
  }
}
