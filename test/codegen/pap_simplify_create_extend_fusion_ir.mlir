// RUN: %ecoc %s -emit=mlir-eco 2>&1 | %FileCheck %s
//
// H6.2.5 M1 (P6) structural pin: a single-use papCreate followed by a
// strictly NON-saturating typed papExtend fuses into ONE papCreate whose
// num_captured covers the extend's args (bitmap recomputed from SSA
// types). The partial ESCAPES (returned), so nothing downstream (P1/P4)
// can consume it — the fused create must survive verbatim and no
// papExtend may remain anywhere in the module.

module {
  func.func @add3(%a: i64, %b: i64, %c: i64) -> i64 {
    %ab = eco.int.add %a, %b : i64
    %abc = eco.int.add %ab, %c : i64
    eco.return %abc : i64
  }

  func.func @escape_partial() -> !eco.value {
    %c7 = arith.constant 7 : i64

    %pap = "eco.papCreate"() {
      function = @add3,
      arity = 3 : i64,
      num_captured = 0 : i64,
      unboxed_bitmap = 0 : i64
    } : () -> !eco.value

    %p = "eco.papExtend"(%pap, %c7) {
      remaining_arity = 3 : i64,
      newargs_unboxed_bitmap = 1 : i64,
      _call_kind = "direct_known_segmentation"
    } : (!eco.value, i64) -> !eco.value

    eco.return %p : !eco.value
  }
}

// CHECK: eco.papCreate
// CHECK-SAME: num_captured = 1
// CHECK-NOT: eco.papExtend
