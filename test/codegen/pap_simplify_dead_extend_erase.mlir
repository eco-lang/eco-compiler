// RUN: %ecoc %s -emit=mlir-eco 2>&1 | %FileCheck %s
//
// Structural pin for H6.1 F1+F2: the Array.setHelp shape from the H6.0
// census. P2 fuses the two-extend chain, F1 erases the orphaned
// non-saturating intermediate (papExtend has no purity trait, so no DCE
// can remove it — pre-fix it executed at runtime as an
// allocate-and-discard PAP 156M times per self-compile), and with the
// papCreate back to single-use P1 converts the fused saturated extend to
// a direct call and the Pure papCreate is DCE'd. Also pins F2 (P5): a
// free-standing dead non-saturating extend is erased even without P2
// running first.

// CHECK-NOT: eco.papExtend
// CHECK-NOT: eco.papCreate
// CHECK: "eco.call"(%c7_i64, %c11_i64)

module {
  func.func @band(%a: i64, %b: i64) -> i64 {
    %r = eco.int.and %a, %b : i64
    eco.return %r : i64
  }

  func.func @chain() -> i64 {
    %c7 = arith.constant 7 : i64
    %c11 = arith.constant 11 : i64

    // The <|-styled partial: create, extend one arg, extend to saturation.
    %pap = "eco.papCreate"() {
      function = @band,
      arity = 2 : i64,
      num_captured = 0 : i64,
      unboxed_bitmap = 0 : i64
    } : () -> !eco.value

    %partial = "eco.papExtend"(%pap, %c7) {
      remaining_arity = 2 : i64,
      newargs_unboxed_bitmap = 1 : i64
    } : (!eco.value, i64) -> !eco.value

    %result = "eco.papExtend"(%partial, %c11) {
      remaining_arity = 1 : i64,
      newargs_unboxed_bitmap = 1 : i64
    } : (!eco.value, i64) -> i64

    eco.return %result : i64
  }

  func.func @deadExtendOnly(%f: !eco.value) -> i64 {
    %c3 = arith.constant 3 : i64
    // Dead, strictly non-saturating extend of an opaque closure: P2/P1
    // never see it (no papCreate root); only P5 can erase it.
    %dead = "eco.papExtend"(%f, %c3) {
      remaining_arity = 2 : i64,
      newargs_unboxed_bitmap = 1 : i64
    } : (!eco.value, i64) -> !eco.value
    eco.return %c3 : i64
  }
}
