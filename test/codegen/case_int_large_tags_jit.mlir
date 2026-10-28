// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Multi-way eco.case with case_kind = "int" (CGEN_048). The upstream SCF->CF
// lowering of scf.index_switch casts the selector and the case values to i32
// for cf.switch, so:
//  - a tag of 2^31 or more (5000000000) must not use scf.index_switch: it
//    would be truncated (5000000000 matched 705032704 = 5000000000 mod 2^32).
//    Such cases lower to an i64 scf.if compare chain.
//  - with all tags in [0, 2^31-1] index_switch is used, and the scrutinee is
//    clamped to a non-case sentinel when outside that range, so 2^32 + 7 and
//    -2^32 + 3 no longer alias the tags 7 and 3.
//  - a negative tag also takes the compare chain; with four alternatives the
//    chain nests (its default used to sit in an scf.if without an else
//    region, which failed verification for a value-producing case).

module {
  // Tags beyond i32: i64 compare chain.
  func.func private @classify_large(%n: i64) -> i64 {
    %r = eco.case %n : i64 [5000000000, 7, 0] -> (i64) {case_kind = "int"} {
      %a = arith.constant 1 : i64
      eco.yield %a : i64
    }, {
      %b = arith.constant 2 : i64
      eco.yield %b : i64
    }, {
      %z = arith.constant 0 : i64
      eco.yield %z : i64
    }
    return %r : i64
  }

  // Small tags: scf.index_switch with a clamped scrutinee. The default tag
  // (last) is 0, so the sentinel must avoid only 3 and 7.
  func.func private @classify_small(%n: i64) -> i64 {
    %r = eco.case %n : i64 [3, 7, 0] -> (i64) {case_kind = "int"} {
      %a = arith.constant 1 : i64
      eco.yield %a : i64
    }, {
      %b = arith.constant 2 : i64
      eco.yield %b : i64
    }, {
      %z = arith.constant 0 : i64
      eco.yield %z : i64
    }
    return %r : i64
  }

  // Small tags including 0 as a case value: the sentinel must avoid 0 too.
  func.func private @classify_zero(%n: i64) -> i64 {
    %r = eco.case %n : i64 [0, 1, 2, 9] -> (i64) {case_kind = "int"} {
      %a = arith.constant 1 : i64
      eco.yield %a : i64
    }, {
      %b = arith.constant 2 : i64
      eco.yield %b : i64
    }, {
      %c = arith.constant 3 : i64
      eco.yield %c : i64
    }, {
      %z = arith.constant 0 : i64
      eco.yield %z : i64
    }
    return %r : i64
  }

  // Negative tag, four alternatives: nested i64 compare chain.
  func.func private @classify_neg(%n: i64) -> i64 {
    %r = eco.case %n : i64 [-5, 3, 10, 0] -> (i64) {case_kind = "int"} {
      %a = arith.constant 1 : i64
      eco.yield %a : i64
    }, {
      %b = arith.constant 2 : i64
      eco.yield %b : i64
    }, {
      %c = arith.constant 3 : i64
      eco.yield %c : i64
    }, {
      %z = arith.constant 0 : i64
      eco.yield %z : i64
    }
    return %r : i64
  }

  func.func @main() -> i64 {
    %big = arith.constant 5000000000 : i64
    %trunc = arith.constant 705032704 : i64
    %seven = arith.constant 7 : i64
    %three = arith.constant 3 : i64
    %wrap7 = arith.constant 4294967303 : i64
    %negwrap3 = arith.constant -4294967293 : i64
    %wrap0 = arith.constant 4294967296 : i64
    %neg = arith.constant -1 : i64
    %two = arith.constant 2 : i64

    %l1 = func.call @classify_large(%big) : (i64) -> i64
    eco.dbg %l1 : i64
    // CHECK: [eco.dbg] 1
    %l2 = func.call @classify_large(%trunc) : (i64) -> i64
    eco.dbg %l2 : i64
    // CHECK-NEXT: [eco.dbg] 0
    %l3 = func.call @classify_large(%seven) : (i64) -> i64
    eco.dbg %l3 : i64
    // CHECK-NEXT: [eco.dbg] 2

    %s1 = func.call @classify_small(%three) : (i64) -> i64
    eco.dbg %s1 : i64
    // CHECK-NEXT: [eco.dbg] 1
    %s2 = func.call @classify_small(%seven) : (i64) -> i64
    eco.dbg %s2 : i64
    // CHECK-NEXT: [eco.dbg] 2
    %s3 = func.call @classify_small(%wrap7) : (i64) -> i64
    eco.dbg %s3 : i64
    // CHECK-NEXT: [eco.dbg] 0
    %s4 = func.call @classify_small(%negwrap3) : (i64) -> i64
    eco.dbg %s4 : i64
    // CHECK-NEXT: [eco.dbg] 0
    %s5 = func.call @classify_small(%neg) : (i64) -> i64
    eco.dbg %s5 : i64
    // CHECK-NEXT: [eco.dbg] 0

    %z1 = func.call @classify_zero(%wrap0) : (i64) -> i64
    eco.dbg %z1 : i64
    // CHECK-NEXT: [eco.dbg] 0
    %z2 = func.call @classify_zero(%two) : (i64) -> i64
    eco.dbg %z2 : i64
    // CHECK-NEXT: [eco.dbg] 3
    %z3 = func.call @classify_zero(%neg) : (i64) -> i64
    eco.dbg %z3 : i64
    // CHECK-NEXT: [eco.dbg] 0

    %m5 = arith.constant -5 : i64
    %ten = arith.constant 10 : i64
    %n1 = func.call @classify_neg(%m5) : (i64) -> i64
    eco.dbg %n1 : i64
    // CHECK-NEXT: [eco.dbg] 1
    %n2 = func.call @classify_neg(%ten) : (i64) -> i64
    eco.dbg %n2 : i64
    // CHECK-NEXT: [eco.dbg] 3
    %n3 = func.call @classify_neg(%neg) : (i64) -> i64
    eco.dbg %n3 : i64
    // CHECK-NEXT: [eco.dbg] 0

    %ret = arith.constant 0 : i64
    return %ret : i64
  }
}
