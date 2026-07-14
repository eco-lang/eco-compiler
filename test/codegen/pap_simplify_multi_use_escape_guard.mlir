// RUN: %ecoc %s -emit=mlir-eco 2>&1 | %FileCheck %s
//
// P4 escape guard (HOF-elimination plan H4.1): one use of the papCreate is
// a saturated application, but the OTHER use passes the closure as a
// NEWARG of a different papExtend (the closure escapes into another PAP's
// captures). The papCreate must SURVIVE — only all-uses-qualify creates
// are elided. (P1 also stays away: not single-use.)

module {
  func.func @add(%a: i64, %b: i64) -> i64 {
    %sum = eco.int.add %a, %b : i64
    eco.return %sum : i64
  }

  func.func @applyTwice(%f: !eco.value, %x: i64) -> i64 {
    %r = "eco.papExtend"(%f, %x) {
      newargs_unboxed_bitmap = 1 : i64
    } : (!eco.value, i64) -> i64
    eco.return %r : i64
  }

  // CHECK-LABEL: @main
  // CHECK: eco.papCreate
  func.func @main() -> i64 {
    %c5 = arith.constant 5 : i64
    %c3 = arith.constant 3 : i64

    %pap = "eco.papCreate"(%c5) {
      function = @add,
      arity = 2 : i64,
      num_captured = 1 : i64,
      unboxed_bitmap = 1 : i64
    } : (i64) -> !eco.value

    // Qualifying use: saturated typed extend.
    %r1 = "eco.papExtend"(%pap, %c3) {
      remaining_arity = 1 : i64,
      newargs_unboxed_bitmap = 1 : i64
    } : (!eco.value, i64) -> i64

    // Escaping use: %pap as a NEWARG (captured into another PAP).
    %outer = "eco.papCreate"() {
      function = @applyTwice,
      arity = 2 : i64,
      num_captured = 0 : i64,
      unboxed_bitmap = 0 : i64
    } : () -> !eco.value
    %r2 = "eco.papExtend"(%outer, %pap, %c3) {
      remaining_arity = 2 : i64,
      newargs_unboxed_bitmap = 4 : i64
    } : (!eco.value, !eco.value, i64) -> i64

    %sum = eco.int.add %r1, %r2 : i64
    return %sum : i64
  }
}
