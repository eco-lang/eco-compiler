// RUN: %ecoc %s -emit=mlir-eco 2>&1 | %FileCheck %s
//
// B16 (plans/wide-object-tail-kind-words-phase-0.md): EcoPAPSimplify's chain fusion
// (P2) must not build a papExtend with more newargs than the verifier allows. Two
// typed extends of 15 Int args each (arity 32) fuse into one 30-newarg extend.
// Phase 1: fusion declined above 25 (both extends survived). Phase 2 (step 2.7): the
// cap is 2047 and the fused op carries `slot_kinds` (30 entries), no legacy bitmap.
//
// @partial: the base is a papCreate, so P6 (create+extend fusion) then folds the
// fused extend into the create: ONE papCreate with 31 captures, 31 slot_kinds.
// @partial_param: the base is a parameter, so P6 cannot apply and the P2 result is
// visible: ONE fused 30-newarg papExtend.

module {
  func.func @sum32(%a0: i64, %a1: i64, %a2: i64, %a3: i64, %a4: i64, %a5: i64, %a6: i64, %a7: i64, %a8: i64, %a9: i64, %a10: i64, %a11: i64, %a12: i64, %a13: i64, %a14: i64, %a15: i64, %a16: i64, %a17: i64, %a18: i64, %a19: i64, %a20: i64, %a21: i64, %a22: i64, %a23: i64, %a24: i64, %a25: i64, %a26: i64, %a27: i64, %a28: i64, %a29: i64, %a30: i64, %a31: i64) -> i64 {
    %s0 = eco.int.add %a0, %a1 : i64
    %s1 = eco.int.add %s0, %a2 : i64
    %s2 = eco.int.add %s1, %a3 : i64
    %s3 = eco.int.add %s2, %a4 : i64
    %s4 = eco.int.add %s3, %a5 : i64
    %s5 = eco.int.add %s4, %a6 : i64
    %s6 = eco.int.add %s5, %a7 : i64
    %s7 = eco.int.add %s6, %a8 : i64
    %s8 = eco.int.add %s7, %a9 : i64
    %s9 = eco.int.add %s8, %a10 : i64
    %s10 = eco.int.add %s9, %a11 : i64
    %s11 = eco.int.add %s10, %a12 : i64
    %s12 = eco.int.add %s11, %a13 : i64
    %s13 = eco.int.add %s12, %a14 : i64
    %s14 = eco.int.add %s13, %a15 : i64
    %s15 = eco.int.add %s14, %a16 : i64
    %s16 = eco.int.add %s15, %a17 : i64
    %s17 = eco.int.add %s16, %a18 : i64
    %s18 = eco.int.add %s17, %a19 : i64
    %s19 = eco.int.add %s18, %a20 : i64
    %s20 = eco.int.add %s19, %a21 : i64
    %s21 = eco.int.add %s20, %a22 : i64
    %s22 = eco.int.add %s21, %a23 : i64
    %s23 = eco.int.add %s22, %a24 : i64
    %s24 = eco.int.add %s23, %a25 : i64
    %s25 = eco.int.add %s24, %a26 : i64
    %s26 = eco.int.add %s25, %a27 : i64
    %s27 = eco.int.add %s26, %a28 : i64
    %s28 = eco.int.add %s27, %a29 : i64
    %s29 = eco.int.add %s28, %a30 : i64
    %s30 = eco.int.add %s29, %a31 : i64
    eco.return %s30 : i64
  }

  func.func @partial() -> !eco.value {
    %c0 = arith.constant 0 : i64
    %c1 = arith.constant 1 : i64
    %c2 = arith.constant 2 : i64
    %c3 = arith.constant 3 : i64
    %c4 = arith.constant 4 : i64
    %c5 = arith.constant 5 : i64
    %c6 = arith.constant 6 : i64
    %c7 = arith.constant 7 : i64
    %c8 = arith.constant 8 : i64
    %c9 = arith.constant 9 : i64
    %c10 = arith.constant 10 : i64
    %c11 = arith.constant 11 : i64
    %c12 = arith.constant 12 : i64
    %c13 = arith.constant 13 : i64
    %c14 = arith.constant 14 : i64
    %c15 = arith.constant 15 : i64
    %c16 = arith.constant 16 : i64
    %c17 = arith.constant 17 : i64
    %c18 = arith.constant 18 : i64
    %c19 = arith.constant 19 : i64
    %c20 = arith.constant 20 : i64
    %c21 = arith.constant 21 : i64
    %c22 = arith.constant 22 : i64
    %c23 = arith.constant 23 : i64
    %c24 = arith.constant 24 : i64
    %c25 = arith.constant 25 : i64
    %c26 = arith.constant 26 : i64
    %c27 = arith.constant 27 : i64
    %c28 = arith.constant 28 : i64
    %c29 = arith.constant 29 : i64
    %c30 = arith.constant 30 : i64
    %c31 = arith.constant 31 : i64
    %pap = "eco.papCreate"(%c0) {
      function = @sum32,
      arity = 32 : i64,
      num_captured = 1 : i64,
      unboxed_bitmap = 1 : i64
    } : (i64) -> !eco.value
    %p1 = "eco.papExtend"(%pap, %c1, %c2, %c3, %c4, %c5, %c6, %c7, %c8, %c9, %c10, %c11, %c12, %c13, %c14, %c15) {
      remaining_arity = 31 : i64,
      newargs_unboxed_bitmap = 357913941 : i64
    } : (!eco.value, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64) -> !eco.value
    %p2 = "eco.papExtend"(%p1, %c16, %c17, %c18, %c19, %c20, %c21, %c22, %c23, %c24, %c25, %c26, %c27, %c28, %c29, %c30) {
      remaining_arity = 16 : i64,
      newargs_unboxed_bitmap = 357913941 : i64
    } : (!eco.value, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64) -> !eco.value
    return %p2 : !eco.value
  }
  func.func @partial_param(%f: !eco.value) -> !eco.value {
    %c1 = arith.constant 1 : i64
    %p1 = "eco.papExtend"(%f, %c1, %c1, %c1, %c1, %c1, %c1, %c1, %c1, %c1, %c1, %c1, %c1, %c1, %c1, %c1) {
      remaining_arity = 31 : i64,
      newargs_unboxed_bitmap = 357913941 : i64
    } : (!eco.value, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64) -> !eco.value
    %p2 = "eco.papExtend"(%p1, %c1, %c1, %c1, %c1, %c1, %c1, %c1, %c1, %c1, %c1, %c1, %c1, %c1, %c1, %c1) {
      remaining_arity = 16 : i64,
      newargs_unboxed_bitmap = 357913941 : i64
    } : (!eco.value, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64) -> !eco.value
    return %p2 : !eco.value
  }
}

// The harness is order-insensitive (CHECK-NOT = absent from the whole output).
// The whole property dict is pinned, so no legacy bitmap is present; no op keeps the
// second extend's remaining_arity (16), so both chains fused.
// CHECK-NOT: error
// CHECK-NOT: unboxed_bitmap
// CHECK-NOT: remaining_arity = 16
// CHECK: "eco.papCreate"{{.*}}<{_result_kind = 0 : i8, arity = 32 : i64, function = @sum32, num_captured = 31 : i64, slot_kinds = array<i8: 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1>}>
// CHECK: "eco.papExtend"(%arg0{{.*}}<{_result_kind = 0 : i8, remaining_arity = 31 : i64, slot_kinds = array<i8: 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1>}>
