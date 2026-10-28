// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// eco.case with case_kind = "chr" on an unboxed i32 Char (a Unicode code
// point) must match code points >= U+8000 and astral ones. With the old
// 16-bit Char the SCF lowering sign-extended the scrutinee into the
// scf.index_switch selector (arith.index_cast), so every char >= U+8000 fell
// through to the default arm; the i32 Char is zero-extended (index_castui).

module {
  // Multi-way char case (scf.index_switch path): returns the arm index.
  func.func private @classify(%c: i32) -> i64 {
    %r = eco.case %c : i32 [65, 63488, 65535, 128512, 1114111, 0] -> (i64) {case_kind = "chr"} {
      %a = arith.constant 1 : i64
      eco.yield %a : i64
    }, {
      %b = arith.constant 2 : i64
      eco.yield %b : i64
    }, {
      %d = arith.constant 3 : i64
      eco.yield %d : i64
    }, {
      %e = arith.constant 4 : i64
      eco.yield %e : i64
    }, {
      %f = arith.constant 5 : i64
      eco.yield %f : i64
    }, {
      %z = arith.constant 0 : i64
      eco.yield %z : i64
    }
    return %r : i64
  }

  // Two-way char case (scf.if path): 1 for the grinning face, else 0.
  // The two-way lowering tests `scrutinee == tags[1]` and takes alternative 1
  // when it holds, alternative 0 otherwise (EcoControlFlowToSCF.cpp
  // CaseToScfIfPattern), so the tested code point is the second tag.
  func.func private @is_grin(%c: i32) -> i64 {
    %r = eco.case %c : i32 [0, 128512] -> (i64) {case_kind = "chr"} {
      %f = arith.constant 0 : i64
      eco.yield %f : i64
    }, {
      %t = arith.constant 1 : i64
      eco.yield %t : i64
    }
    return %r : i64
  }

  func.func @main() -> i64 {
    %cA = arith.constant 65 : i32
    %cPua = arith.constant 63488 : i32
    %cFFFF = arith.constant 65535 : i32
    %cGrin = arith.constant 128512 : i32
    %cTop = arith.constant 1114111 : i32
    %cOther = arith.constant 66 : i32

    %r1 = func.call @classify(%cA) : (i32) -> i64
    eco.dbg %r1 : i64
    // CHECK: [eco.dbg] 1
    %r2 = func.call @classify(%cPua) : (i32) -> i64
    eco.dbg %r2 : i64
    // CHECK-NEXT: [eco.dbg] 2
    %r3 = func.call @classify(%cFFFF) : (i32) -> i64
    eco.dbg %r3 : i64
    // CHECK-NEXT: [eco.dbg] 3
    %r4 = func.call @classify(%cGrin) : (i32) -> i64
    eco.dbg %r4 : i64
    // CHECK-NEXT: [eco.dbg] 4
    %r5 = func.call @classify(%cTop) : (i32) -> i64
    eco.dbg %r5 : i64
    // CHECK-NEXT: [eco.dbg] 5
    %r6 = func.call @classify(%cOther) : (i32) -> i64
    eco.dbg %r6 : i64
    // CHECK-NEXT: [eco.dbg] 0

    %g1 = func.call @is_grin(%cGrin) : (i32) -> i64
    eco.dbg %g1 : i64
    // CHECK-NEXT: [eco.dbg] 1
    %g2 = func.call @is_grin(%cPua) : (i32) -> i64
    eco.dbg %g2 : i64
    // CHECK-NEXT: [eco.dbg] 0

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
