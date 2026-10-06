// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Phase 2 (plans/wide-object-tail-kind-words-phase-2.md 2.6.7): kinds on both sides of the
// inline/extension boundary. Target params: Float at 19 and 20 (inline slot 19, ext slot 20),
// Char at 51 and 52 (the second ext word), Int elsewhere; stage arity 53 (K = 2). A papCreate
// captures slots 0..20 (slot 20's kind lives in ext word 0), papExtend adds slots 21..50
// (eco_pap_extend_l copies the ext words), then the two Char args saturate. The target
// weights each param by (i+1), so a slot read at the wrong kind or position changes the sum.

module {
  func.func @k53(%p0: i64, %p1: i64, %p2: i64, %p3: i64, %p4: i64, %p5: i64, %p6: i64, %p7: i64, %p8: i64, %p9: i64, %p10: i64, %p11: i64, %p12: i64, %p13: i64, %p14: i64, %p15: i64, %p16: i64, %p17: i64, %p18: i64, %p19: f64, %p20: f64, %p21: i64, %p22: i64, %p23: i64, %p24: i64, %p25: i64, %p26: i64, %p27: i64, %p28: i64, %p29: i64, %p30: i64, %p31: i64, %p32: i64, %p33: i64, %p34: i64, %p35: i64, %p36: i64, %p37: i64, %p38: i64, %p39: i64, %p40: i64, %p41: i64, %p42: i64, %p43: i64, %p44: i64, %p45: i64, %p46: i64, %p47: i64, %p48: i64, %p49: i64, %p50: i64, %p51: i16, %p52: i16) -> i64 {
    %w0 = arith.constant 1 : i64
    %t0 = eco.int.mul %p0, %w0 : i64
    %w1 = arith.constant 2 : i64
    %t1 = eco.int.mul %p1, %w1 : i64
    %w2 = arith.constant 3 : i64
    %t2 = eco.int.mul %p2, %w2 : i64
    %w3 = arith.constant 4 : i64
    %t3 = eco.int.mul %p3, %w3 : i64
    %w4 = arith.constant 5 : i64
    %t4 = eco.int.mul %p4, %w4 : i64
    %w5 = arith.constant 6 : i64
    %t5 = eco.int.mul %p5, %w5 : i64
    %w6 = arith.constant 7 : i64
    %t6 = eco.int.mul %p6, %w6 : i64
    %w7 = arith.constant 8 : i64
    %t7 = eco.int.mul %p7, %w7 : i64
    %w8 = arith.constant 9 : i64
    %t8 = eco.int.mul %p8, %w8 : i64
    %w9 = arith.constant 10 : i64
    %t9 = eco.int.mul %p9, %w9 : i64
    %w10 = arith.constant 11 : i64
    %t10 = eco.int.mul %p10, %w10 : i64
    %w11 = arith.constant 12 : i64
    %t11 = eco.int.mul %p11, %w11 : i64
    %w12 = arith.constant 13 : i64
    %t12 = eco.int.mul %p12, %w12 : i64
    %w13 = arith.constant 14 : i64
    %t13 = eco.int.mul %p13, %w13 : i64
    %w14 = arith.constant 15 : i64
    %t14 = eco.int.mul %p14, %w14 : i64
    %w15 = arith.constant 16 : i64
    %t15 = eco.int.mul %p15, %w15 : i64
    %w16 = arith.constant 17 : i64
    %t16 = eco.int.mul %p16, %w16 : i64
    %w17 = arith.constant 18 : i64
    %t17 = eco.int.mul %p17, %w17 : i64
    %w18 = arith.constant 19 : i64
    %t18 = eco.int.mul %p18, %w18 : i64
    %k19 = arith.constant 1000.0 : f64
    %m19 = eco.float.mul %p19, %k19 : f64
    %u19 = eco.float.truncate %m19 : f64 -> i64
    %w19 = arith.constant 20 : i64
    %t19 = eco.int.mul %u19, %w19 : i64
    %k20 = arith.constant 1000.0 : f64
    %m20 = eco.float.mul %p20, %k20 : f64
    %u20 = eco.float.truncate %m20 : f64 -> i64
    %w20 = arith.constant 21 : i64
    %t20 = eco.int.mul %u20, %w20 : i64
    %w21 = arith.constant 22 : i64
    %t21 = eco.int.mul %p21, %w21 : i64
    %w22 = arith.constant 23 : i64
    %t22 = eco.int.mul %p22, %w22 : i64
    %w23 = arith.constant 24 : i64
    %t23 = eco.int.mul %p23, %w23 : i64
    %w24 = arith.constant 25 : i64
    %t24 = eco.int.mul %p24, %w24 : i64
    %w25 = arith.constant 26 : i64
    %t25 = eco.int.mul %p25, %w25 : i64
    %w26 = arith.constant 27 : i64
    %t26 = eco.int.mul %p26, %w26 : i64
    %w27 = arith.constant 28 : i64
    %t27 = eco.int.mul %p27, %w27 : i64
    %w28 = arith.constant 29 : i64
    %t28 = eco.int.mul %p28, %w28 : i64
    %w29 = arith.constant 30 : i64
    %t29 = eco.int.mul %p29, %w29 : i64
    %w30 = arith.constant 31 : i64
    %t30 = eco.int.mul %p30, %w30 : i64
    %w31 = arith.constant 32 : i64
    %t31 = eco.int.mul %p31, %w31 : i64
    %w32 = arith.constant 33 : i64
    %t32 = eco.int.mul %p32, %w32 : i64
    %w33 = arith.constant 34 : i64
    %t33 = eco.int.mul %p33, %w33 : i64
    %w34 = arith.constant 35 : i64
    %t34 = eco.int.mul %p34, %w34 : i64
    %w35 = arith.constant 36 : i64
    %t35 = eco.int.mul %p35, %w35 : i64
    %w36 = arith.constant 37 : i64
    %t36 = eco.int.mul %p36, %w36 : i64
    %w37 = arith.constant 38 : i64
    %t37 = eco.int.mul %p37, %w37 : i64
    %w38 = arith.constant 39 : i64
    %t38 = eco.int.mul %p38, %w38 : i64
    %w39 = arith.constant 40 : i64
    %t39 = eco.int.mul %p39, %w39 : i64
    %w40 = arith.constant 41 : i64
    %t40 = eco.int.mul %p40, %w40 : i64
    %w41 = arith.constant 42 : i64
    %t41 = eco.int.mul %p41, %w41 : i64
    %w42 = arith.constant 43 : i64
    %t42 = eco.int.mul %p42, %w42 : i64
    %w43 = arith.constant 44 : i64
    %t43 = eco.int.mul %p43, %w43 : i64
    %w44 = arith.constant 45 : i64
    %t44 = eco.int.mul %p44, %w44 : i64
    %w45 = arith.constant 46 : i64
    %t45 = eco.int.mul %p45, %w45 : i64
    %w46 = arith.constant 47 : i64
    %t46 = eco.int.mul %p46, %w46 : i64
    %w47 = arith.constant 48 : i64
    %t47 = eco.int.mul %p47, %w47 : i64
    %w48 = arith.constant 49 : i64
    %t48 = eco.int.mul %p48, %w48 : i64
    %w49 = arith.constant 50 : i64
    %t49 = eco.int.mul %p49, %w49 : i64
    %w50 = arith.constant 51 : i64
    %t50 = eco.int.mul %p50, %w50 : i64
    %u51 = eco.char.toInt %p51 : i16 -> i64
    %w51 = arith.constant 52 : i64
    %t51 = eco.int.mul %u51, %w51 : i64
    %u52 = eco.char.toInt %p52 : i16 -> i64
    %w52 = arith.constant 53 : i64
    %t52 = eco.int.mul %u52, %w52 : i64
    %s1 = eco.int.add %t0, %t1 : i64
    %s2 = eco.int.add %s1, %t2 : i64
    %s3 = eco.int.add %s2, %t3 : i64
    %s4 = eco.int.add %s3, %t4 : i64
    %s5 = eco.int.add %s4, %t5 : i64
    %s6 = eco.int.add %s5, %t6 : i64
    %s7 = eco.int.add %s6, %t7 : i64
    %s8 = eco.int.add %s7, %t8 : i64
    %s9 = eco.int.add %s8, %t9 : i64
    %s10 = eco.int.add %s9, %t10 : i64
    %s11 = eco.int.add %s10, %t11 : i64
    %s12 = eco.int.add %s11, %t12 : i64
    %s13 = eco.int.add %s12, %t13 : i64
    %s14 = eco.int.add %s13, %t14 : i64
    %s15 = eco.int.add %s14, %t15 : i64
    %s16 = eco.int.add %s15, %t16 : i64
    %s17 = eco.int.add %s16, %t17 : i64
    %s18 = eco.int.add %s17, %t18 : i64
    %s19 = eco.int.add %s18, %t19 : i64
    %s20 = eco.int.add %s19, %t20 : i64
    %s21 = eco.int.add %s20, %t21 : i64
    %s22 = eco.int.add %s21, %t22 : i64
    %s23 = eco.int.add %s22, %t23 : i64
    %s24 = eco.int.add %s23, %t24 : i64
    %s25 = eco.int.add %s24, %t25 : i64
    %s26 = eco.int.add %s25, %t26 : i64
    %s27 = eco.int.add %s26, %t27 : i64
    %s28 = eco.int.add %s27, %t28 : i64
    %s29 = eco.int.add %s28, %t29 : i64
    %s30 = eco.int.add %s29, %t30 : i64
    %s31 = eco.int.add %s30, %t31 : i64
    %s32 = eco.int.add %s31, %t32 : i64
    %s33 = eco.int.add %s32, %t33 : i64
    %s34 = eco.int.add %s33, %t34 : i64
    %s35 = eco.int.add %s34, %t35 : i64
    %s36 = eco.int.add %s35, %t36 : i64
    %s37 = eco.int.add %s36, %t37 : i64
    %s38 = eco.int.add %s37, %t38 : i64
    %s39 = eco.int.add %s38, %t39 : i64
    %s40 = eco.int.add %s39, %t40 : i64
    %s41 = eco.int.add %s40, %t41 : i64
    %s42 = eco.int.add %s41, %t42 : i64
    %s43 = eco.int.add %s42, %t43 : i64
    %s44 = eco.int.add %s43, %t44 : i64
    %s45 = eco.int.add %s44, %t45 : i64
    %s46 = eco.int.add %s45, %t46 : i64
    %s47 = eco.int.add %s46, %t47 : i64
    %s48 = eco.int.add %s47, %t48 : i64
    %s49 = eco.int.add %s48, %t49 : i64
    %s50 = eco.int.add %s49, %t50 : i64
    %s51 = eco.int.add %s50, %t51 : i64
    %s52 = eco.int.add %s51, %t52 : i64
    eco.return %s52 : i64
  }

  func.func @drive(%f: !eco.value) -> i64 {
    %b21 = arith.constant 22 : i64
    %b22 = arith.constant 23 : i64
    %b23 = arith.constant 24 : i64
    %b24 = arith.constant 25 : i64
    %b25 = arith.constant 26 : i64
    %b26 = arith.constant 27 : i64
    %b27 = arith.constant 28 : i64
    %b28 = arith.constant 29 : i64
    %b29 = arith.constant 30 : i64
    %b30 = arith.constant 31 : i64
    %b31 = arith.constant 32 : i64
    %b32 = arith.constant 33 : i64
    %b33 = arith.constant 34 : i64
    %b34 = arith.constant 35 : i64
    %b35 = arith.constant 36 : i64
    %b36 = arith.constant 37 : i64
    %b37 = arith.constant 38 : i64
    %b38 = arith.constant 39 : i64
    %b39 = arith.constant 40 : i64
    %b40 = arith.constant 41 : i64
    %b41 = arith.constant 42 : i64
    %b42 = arith.constant 43 : i64
    %b43 = arith.constant 44 : i64
    %b44 = arith.constant 45 : i64
    %b45 = arith.constant 46 : i64
    %b46 = arith.constant 47 : i64
    %b47 = arith.constant 48 : i64
    %b48 = arith.constant 49 : i64
    %b49 = arith.constant 50 : i64
    %b50 = arith.constant 51 : i64
    %b51 = arith.constant 116 : i16
    %b52 = arith.constant 117 : i16
    %p1 = "eco.papExtend"(%f, %b21, %b22, %b23, %b24, %b25, %b26, %b27, %b28, %b29, %b30, %b31, %b32, %b33, %b34, %b35, %b36, %b37, %b38, %b39, %b40, %b41, %b42, %b43, %b44, %b45, %b46, %b47, %b48, %b49, %b50) {slot_kinds = array<i8: 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1>, remaining_arity = 32 : i64
    } : (!eco.value, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64) -> !eco.value
    eco.dbg %p1 : !eco.value
    %r = "eco.papExtend"(%p1, %b51, %b52) {slot_kinds = array<i8: 3, 3>, remaining_arity = 2 : i64
    } : (!eco.value, i16, i16) -> i64
    eco.return %r : i64
  }

  func.func @main() -> i64 {
    %a0 = arith.constant 1 : i64
    %a1 = arith.constant 2 : i64
    %a2 = arith.constant 3 : i64
    %a3 = arith.constant 4 : i64
    %a4 = arith.constant 5 : i64
    %a5 = arith.constant 6 : i64
    %a6 = arith.constant 7 : i64
    %a7 = arith.constant 8 : i64
    %a8 = arith.constant 9 : i64
    %a9 = arith.constant 10 : i64
    %a10 = arith.constant 11 : i64
    %a11 = arith.constant 12 : i64
    %a12 = arith.constant 13 : i64
    %a13 = arith.constant 14 : i64
    %a14 = arith.constant 15 : i64
    %a15 = arith.constant 16 : i64
    %a16 = arith.constant 17 : i64
    %a17 = arith.constant 18 : i64
    %a18 = arith.constant 19 : i64
    %a19 = arith.constant 19.25 : f64
    %a20 = arith.constant 20.25 : f64
    %pap = "eco.papCreate"(%a0, %a1, %a2, %a3, %a4, %a5, %a6, %a7, %a8, %a9, %a10, %a11, %a12, %a13, %a14, %a15, %a16, %a17, %a18, %a19, %a20) {slot_kinds = array<i8: 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 2, 2>, function = @k53,
      arity = 53 : i64,
      num_captured = 21 : i64
    } : (i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, f64, f64) -> !eco.value
    %r = func.call @drive(%pap) : (!eco.value) -> i64
    eco.dbg %r : i64
    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}

// CHECK: <fn>
// CHECK: 867168
