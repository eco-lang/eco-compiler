// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// eco.char.toInt (Char.toCode) of encoded case-mapping results (KERN_008,
// plans/char-case-mapping-elm-exact.md Step 2): the first code point, value & 0x1FFFFF.
// The values go through a call so the mask is not constant-folded before lowering.

module {
  func.func private @code(%c: i32) -> i64 {
    %r = eco.char.toInt %c : i32 -> i64
    eco.return %r : i64
  }

  func.func @main() -> i64 {
    // "SS" (rank 9) -> S
    %c0 = arith.constant 20971603 : i32
    %r0 = func.call @code(%c0) : (i32) -> i64
    %b0 = eco.box %r0 : i64 -> !eco.value
    eco.dbg %b0 : !eco.value
    // CHECK: 83
    // U+0399 + 2 more (rank 40) -> U+0399
    %c1 = arith.constant 85984153 : i32
    %r1 = func.call @code(%c1) : (i32) -> i64
    %b1 = eco.box %r1 : i64 -> !eco.value
    eco.dbg %b1 : !eco.value
    // CHECK: 921
    // rank field all ones -> A
    %c2 = arith.constant 534773825 : i32
    %r2 = func.call @code(%c2) : (i32) -> i64
    %b2 = eco.box %r2 : i64 -> !eco.value
    eco.dbg %b2 : !eco.value
    // CHECK: 65
    // ordinary 0x10FFFF unchanged
    %c3 = arith.constant 1114111 : i32
    %r3 = func.call @code(%c3) : (i32) -> i64
    %b3 = eco.box %r3 : i64 -> !eco.value
    eco.dbg %b3 : !eco.value
    // CHECK: 1114111
    // ordinary astral unchanged
    %c4 = arith.constant 128512 : i32
    %r4 = func.call @code(%c4) : (i32) -> i64
    %b4 = eco.box %r4 : i64 -> !eco.value
    eco.dbg %b4 : !eco.value
    // CHECK: 128512
    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
