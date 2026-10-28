// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Char ordering with encoded case-mapping results (KERN_008, plans/char-case-mapping-elm-exact.md
// Step 2): the eco.char.lt/le/gt/ge/cmp_order lowerings compare rotl32(v, 11), so an encoded
// value 0x53 | (rank+1) << 21 ("S" followed by more) sorts after "S" and before "T", as a JS
// UTF-16 string comparison does. Values (synthetic ranks, not the table's):
//   R=0x52 < S=0x53 < e0=0x200053 < e1=0x400053 < T=0x54 < 0xE000 < 0x1F600
// @probe(a, b) returns lt + 2*le + 4*gt + 8*ge + 16*eq + 32*ne + 100*ord, where ord is the
// branch eco.case takes on eco.char.cmp_order (1 LT, 2 EQ, 3 GT; EcoCompareCaseRewrite turns it
// into eco.char.lt/gt). The arguments go through a call so nothing is constant-folded early.

module {
  func.func private @probe(%a: i32, %b: i32) -> i64 {
    %lt = eco.char.lt %a, %b : i32
    %ltx = arith.extui %lt : i1 to i64
    %ltw = arith.constant 1 : i64
    %ltm = arith.muli %ltx, %ltw : i64
    %le = eco.char.le %a, %b : i32
    %lex = arith.extui %le : i1 to i64
    %lew = arith.constant 2 : i64
    %lem = arith.muli %lex, %lew : i64
    %gt = eco.char.gt %a, %b : i32
    %gtx = arith.extui %gt : i1 to i64
    %gtw = arith.constant 4 : i64
    %gtm = arith.muli %gtx, %gtw : i64
    %ge = eco.char.ge %a, %b : i32
    %gex = arith.extui %ge : i1 to i64
    %gew = arith.constant 8 : i64
    %gem = arith.muli %gex, %gew : i64
    %eq = eco.char.eq %a, %b : i32
    %eqx = arith.extui %eq : i1 to i64
    %eqw = arith.constant 16 : i64
    %eqm = arith.muli %eqx, %eqw : i64
    %ne = eco.char.ne %a, %b : i32
    %nex = arith.extui %ne : i1 to i64
    %new = arith.constant 32 : i64
    %nem = arith.muli %nex, %new : i64
    %s1 = arith.addi %ltm, %lem : i64
    %s2 = arith.addi %s1, %gtm : i64
    %s3 = arith.addi %s2, %gem : i64
    %s4 = arith.addi %s3, %eqm : i64
    %s5 = arith.addi %s4, %nem : i64
    %o = eco.char.cmp_order %a, %b : i32
    %r = eco.case %o : !eco.value [0, 1, 2] -> (i64) {case_kind = "ctor"} {
      %c1 = arith.constant 100 : i64
      eco.yield %c1 : i64
    }, {
      %c2 = arith.constant 200 : i64
      eco.yield %c2 : i64
    }, {
      %c3 = arith.constant 300 : i64
      eco.yield %c3 : i64
    }
    %t = arith.addi %s5, %r : i64
    eco.return %t : i64
  }

  func.func @main() -> i64 {
    %vR = arith.constant 82 : i32
    %vS = arith.constant 83 : i32
    %ve0 = arith.constant 2097235 : i32
    %ve1 = arith.constant 4194387 : i32
    %vT = arith.constant 84 : i32
    %vE000 = arith.constant 57344 : i32
    %v1F600 = arith.constant 128512 : i32
    %r0 = func.call @probe(%vR, %vR) : (i32, i32) -> i64
    %b0 = eco.box %r0 : i64 -> !eco.value
    eco.dbg %b0 : !eco.value
    // CHECK: 226
    %r1 = func.call @probe(%vR, %vS) : (i32, i32) -> i64
    %b1 = eco.box %r1 : i64 -> !eco.value
    eco.dbg %b1 : !eco.value
    // CHECK: 135
    %r2 = func.call @probe(%vR, %ve0) : (i32, i32) -> i64
    %b2 = eco.box %r2 : i64 -> !eco.value
    eco.dbg %b2 : !eco.value
    // CHECK: 135
    %r3 = func.call @probe(%vR, %ve1) : (i32, i32) -> i64
    %b3 = eco.box %r3 : i64 -> !eco.value
    eco.dbg %b3 : !eco.value
    // CHECK: 135
    %r4 = func.call @probe(%vR, %vT) : (i32, i32) -> i64
    %b4 = eco.box %r4 : i64 -> !eco.value
    eco.dbg %b4 : !eco.value
    // CHECK: 135
    %r5 = func.call @probe(%vR, %vE000) : (i32, i32) -> i64
    %b5 = eco.box %r5 : i64 -> !eco.value
    eco.dbg %b5 : !eco.value
    // CHECK: 135
    %r6 = func.call @probe(%vR, %v1F600) : (i32, i32) -> i64
    %b6 = eco.box %r6 : i64 -> !eco.value
    eco.dbg %b6 : !eco.value
    // CHECK: 135
    %r7 = func.call @probe(%vS, %vR) : (i32, i32) -> i64
    %b7 = eco.box %r7 : i64 -> !eco.value
    eco.dbg %b7 : !eco.value
    // CHECK: 344
    %r8 = func.call @probe(%vS, %vS) : (i32, i32) -> i64
    %b8 = eco.box %r8 : i64 -> !eco.value
    eco.dbg %b8 : !eco.value
    // CHECK: 226
    %r9 = func.call @probe(%vS, %ve0) : (i32, i32) -> i64
    %b9 = eco.box %r9 : i64 -> !eco.value
    eco.dbg %b9 : !eco.value
    // CHECK: 135
    %r10 = func.call @probe(%vS, %ve1) : (i32, i32) -> i64
    %b10 = eco.box %r10 : i64 -> !eco.value
    eco.dbg %b10 : !eco.value
    // CHECK: 135
    %r11 = func.call @probe(%vS, %vT) : (i32, i32) -> i64
    %b11 = eco.box %r11 : i64 -> !eco.value
    eco.dbg %b11 : !eco.value
    // CHECK: 135
    %r12 = func.call @probe(%vS, %vE000) : (i32, i32) -> i64
    %b12 = eco.box %r12 : i64 -> !eco.value
    eco.dbg %b12 : !eco.value
    // CHECK: 135
    %r13 = func.call @probe(%vS, %v1F600) : (i32, i32) -> i64
    %b13 = eco.box %r13 : i64 -> !eco.value
    eco.dbg %b13 : !eco.value
    // CHECK: 135
    %r14 = func.call @probe(%ve0, %vR) : (i32, i32) -> i64
    %b14 = eco.box %r14 : i64 -> !eco.value
    eco.dbg %b14 : !eco.value
    // CHECK: 344
    %r15 = func.call @probe(%ve0, %vS) : (i32, i32) -> i64
    %b15 = eco.box %r15 : i64 -> !eco.value
    eco.dbg %b15 : !eco.value
    // CHECK: 344
    %r16 = func.call @probe(%ve0, %ve0) : (i32, i32) -> i64
    %b16 = eco.box %r16 : i64 -> !eco.value
    eco.dbg %b16 : !eco.value
    // CHECK: 226
    %r17 = func.call @probe(%ve0, %ve1) : (i32, i32) -> i64
    %b17 = eco.box %r17 : i64 -> !eco.value
    eco.dbg %b17 : !eco.value
    // CHECK: 135
    %r18 = func.call @probe(%ve0, %vT) : (i32, i32) -> i64
    %b18 = eco.box %r18 : i64 -> !eco.value
    eco.dbg %b18 : !eco.value
    // CHECK: 135
    %r19 = func.call @probe(%ve0, %vE000) : (i32, i32) -> i64
    %b19 = eco.box %r19 : i64 -> !eco.value
    eco.dbg %b19 : !eco.value
    // CHECK: 135
    %r20 = func.call @probe(%ve0, %v1F600) : (i32, i32) -> i64
    %b20 = eco.box %r20 : i64 -> !eco.value
    eco.dbg %b20 : !eco.value
    // CHECK: 135
    %r21 = func.call @probe(%ve1, %vR) : (i32, i32) -> i64
    %b21 = eco.box %r21 : i64 -> !eco.value
    eco.dbg %b21 : !eco.value
    // CHECK: 344
    %r22 = func.call @probe(%ve1, %vS) : (i32, i32) -> i64
    %b22 = eco.box %r22 : i64 -> !eco.value
    eco.dbg %b22 : !eco.value
    // CHECK: 344
    %r23 = func.call @probe(%ve1, %ve0) : (i32, i32) -> i64
    %b23 = eco.box %r23 : i64 -> !eco.value
    eco.dbg %b23 : !eco.value
    // CHECK: 344
    %r24 = func.call @probe(%ve1, %ve1) : (i32, i32) -> i64
    %b24 = eco.box %r24 : i64 -> !eco.value
    eco.dbg %b24 : !eco.value
    // CHECK: 226
    %r25 = func.call @probe(%ve1, %vT) : (i32, i32) -> i64
    %b25 = eco.box %r25 : i64 -> !eco.value
    eco.dbg %b25 : !eco.value
    // CHECK: 135
    %r26 = func.call @probe(%ve1, %vE000) : (i32, i32) -> i64
    %b26 = eco.box %r26 : i64 -> !eco.value
    eco.dbg %b26 : !eco.value
    // CHECK: 135
    %r27 = func.call @probe(%ve1, %v1F600) : (i32, i32) -> i64
    %b27 = eco.box %r27 : i64 -> !eco.value
    eco.dbg %b27 : !eco.value
    // CHECK: 135
    %r28 = func.call @probe(%vT, %vR) : (i32, i32) -> i64
    %b28 = eco.box %r28 : i64 -> !eco.value
    eco.dbg %b28 : !eco.value
    // CHECK: 344
    %r29 = func.call @probe(%vT, %vS) : (i32, i32) -> i64
    %b29 = eco.box %r29 : i64 -> !eco.value
    eco.dbg %b29 : !eco.value
    // CHECK: 344
    %r30 = func.call @probe(%vT, %ve0) : (i32, i32) -> i64
    %b30 = eco.box %r30 : i64 -> !eco.value
    eco.dbg %b30 : !eco.value
    // CHECK: 344
    %r31 = func.call @probe(%vT, %ve1) : (i32, i32) -> i64
    %b31 = eco.box %r31 : i64 -> !eco.value
    eco.dbg %b31 : !eco.value
    // CHECK: 344
    %r32 = func.call @probe(%vT, %vT) : (i32, i32) -> i64
    %b32 = eco.box %r32 : i64 -> !eco.value
    eco.dbg %b32 : !eco.value
    // CHECK: 226
    %r33 = func.call @probe(%vT, %vE000) : (i32, i32) -> i64
    %b33 = eco.box %r33 : i64 -> !eco.value
    eco.dbg %b33 : !eco.value
    // CHECK: 135
    %r34 = func.call @probe(%vT, %v1F600) : (i32, i32) -> i64
    %b34 = eco.box %r34 : i64 -> !eco.value
    eco.dbg %b34 : !eco.value
    // CHECK: 135
    %r35 = func.call @probe(%vE000, %vR) : (i32, i32) -> i64
    %b35 = eco.box %r35 : i64 -> !eco.value
    eco.dbg %b35 : !eco.value
    // CHECK: 344
    %r36 = func.call @probe(%vE000, %vS) : (i32, i32) -> i64
    %b36 = eco.box %r36 : i64 -> !eco.value
    eco.dbg %b36 : !eco.value
    // CHECK: 344
    %r37 = func.call @probe(%vE000, %ve0) : (i32, i32) -> i64
    %b37 = eco.box %r37 : i64 -> !eco.value
    eco.dbg %b37 : !eco.value
    // CHECK: 344
    %r38 = func.call @probe(%vE000, %ve1) : (i32, i32) -> i64
    %b38 = eco.box %r38 : i64 -> !eco.value
    eco.dbg %b38 : !eco.value
    // CHECK: 344
    %r39 = func.call @probe(%vE000, %vT) : (i32, i32) -> i64
    %b39 = eco.box %r39 : i64 -> !eco.value
    eco.dbg %b39 : !eco.value
    // CHECK: 344
    %r40 = func.call @probe(%vE000, %vE000) : (i32, i32) -> i64
    %b40 = eco.box %r40 : i64 -> !eco.value
    eco.dbg %b40 : !eco.value
    // CHECK: 226
    %r41 = func.call @probe(%vE000, %v1F600) : (i32, i32) -> i64
    %b41 = eco.box %r41 : i64 -> !eco.value
    eco.dbg %b41 : !eco.value
    // CHECK: 135
    %r42 = func.call @probe(%v1F600, %vR) : (i32, i32) -> i64
    %b42 = eco.box %r42 : i64 -> !eco.value
    eco.dbg %b42 : !eco.value
    // CHECK: 344
    %r43 = func.call @probe(%v1F600, %vS) : (i32, i32) -> i64
    %b43 = eco.box %r43 : i64 -> !eco.value
    eco.dbg %b43 : !eco.value
    // CHECK: 344
    %r44 = func.call @probe(%v1F600, %ve0) : (i32, i32) -> i64
    %b44 = eco.box %r44 : i64 -> !eco.value
    eco.dbg %b44 : !eco.value
    // CHECK: 344
    %r45 = func.call @probe(%v1F600, %ve1) : (i32, i32) -> i64
    %b45 = eco.box %r45 : i64 -> !eco.value
    eco.dbg %b45 : !eco.value
    // CHECK: 344
    %r46 = func.call @probe(%v1F600, %vT) : (i32, i32) -> i64
    %b46 = eco.box %r46 : i64 -> !eco.value
    eco.dbg %b46 : !eco.value
    // CHECK: 344
    %r47 = func.call @probe(%v1F600, %vE000) : (i32, i32) -> i64
    %b47 = eco.box %r47 : i64 -> !eco.value
    eco.dbg %b47 : !eco.value
    // CHECK: 344
    %r48 = func.call @probe(%v1F600, %v1F600) : (i32, i32) -> i64
    %b48 = eco.box %r48 : i64 -> !eco.value
    eco.dbg %b48 : !eco.value
    // CHECK: 226
    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
