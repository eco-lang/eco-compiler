// RUN: %ecoc %s -emit=llvm 2>&1 | %FileCheck %s --check-prefix=EXP
// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s --check-prefix=JIT
//
// Null-cons embedding (HEAP_044/CGEN_079, plans/null-cons-hpointer-embedding.md):
// eco.constant.null_cons materializes the embedded HPointer word
// (idx << 43) | 0b111 with no allocation. Pins:
//   - the exact word for tag 5: (5 << 43) | 7 = 43980465111047 (EXP leg);
//   - eco.get_tag on the word returns the embedded declaration index via the
//     expandGetTagMarkers diamond's null-cons arm (JIT leg);
//   - eco.case dispatches on the embedded index via the CaseOp lowering's
//     null-cons arm (JIT leg) — the third tag extractor, EcoToLLVMControlFlow.

module {
  func.func @main() -> i64 {
    // (5 << 43) | 0b111
    %v5 = eco.constant.null_cons 5 : !eco.value
    // EXP: 43980465111047

    %t5 = eco.get_tag %v5 : !eco.value -> i32
    %i5 = arith.extui %t5 : i32 to i64
    eco.dbg %i5 : i64
    // JIT: 5

    // Capacity edge: (1023 << 43) | 7 survives the round trip.
    %vmax = eco.constant.null_cons 1023 : !eco.value
    %tmax = eco.get_tag %vmax : !eco.value -> i32
    %imax = arith.extui %tmax : i32 to i64
    eco.dbg %imax : i64
    // JIT: 1023

    // Case dispatch over a null-cons scrutinee: tag 5 selects branch 1.
    %r = eco.case %v5 : !eco.value [3, 5] -> (i64) {case_kind = "ctor"} {
      %a = arith.constant 30 : i64
      eco.yield %a : i64
    }, {
      %b = arith.constant 50 : i64
      eco.yield %b : i64
    }
    eco.dbg %r : i64
    // JIT: 50

    %z = arith.constant 0 : i64
    return %z : i64
  }
}
