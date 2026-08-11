// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s --check-prefix=JIT
//
// kernel-opt-04: eco.string.code_unit_at lowers to a gc-leaf call to
// eco_string_code_unit_at, which forwards to StringOps::charAt.
//
// This op has NO Elm emission — nothing in elm/core maps to charAt — so this
// fixture is the only coverage it has, and it is also what exercises the
// RuntimeSymbols KERNEL_SYM registration (a missing entry fails the JIT leg
// with an unresolved symbol rather than a wrong answer).
//
// The contract being pinned, verbatim from charAt: out-of-range, negative and
// empty all yield 0 rather than trapping. That is deliberate and must not be
// "fixed" — consumers bounds-check against eco.string.length first.

module {
  func.func @main() -> i64 {
    %s = eco.string_literal "abc" : !eco.value
    %i0 = arith.constant 0 : i64
    %i1 = arith.constant 1 : i64
    %i2 = arith.constant 2 : i64
    %i3 = arith.constant 3 : i64
    %ineg = arith.constant -1 : i64

    // In range: 'a' = 97, 'b' = 98, 'c' = 99.
    %c0 = eco.string.code_unit_at %s, %i0
    eco.dbg %c0 : i16
    // JIT: 97
    %c1 = eco.string.code_unit_at %s, %i1
    eco.dbg %c1 : i16
    // JIT: 98
    %c2 = eco.string.code_unit_at %s, %i2
    eco.dbg %c2 : i16
    // JIT: 99

    // One past the end -> 0, not a trap.
    %c3 = eco.string.code_unit_at %s, %i3
    eco.dbg %c3 : i16
    // JIT: 0

    // Negative index -> 0.
    %cneg = eco.string.code_unit_at %s, %ineg
    eco.dbg %cneg : i16
    // JIT: 0

    // Empty string: an embedded constant, so Export::toPtr yields null and the
    // export's own guard returns 0 before charAt is reached.
    %e = eco.string_literal "" : !eco.value
    %ce = eco.string.code_unit_at %e, %i0
    eco.dbg %ce : i16
    // JIT: 0

    %z = arith.constant 0 : i64
    return %z : i64
  }
}
