// RUN: %ecoc %s -emit=mlir 2>&1 | %FileCheck %s
//
// B22 (plans/wide-object-tail-kind-words-phase-1.md step 1b.8): PapCreateOp::verify
// checks per-slot kinds over the REAL captures only (num_captured), never over the
// GC-root operands EcoGCPrepare appends. 25 i64 captures (all-Int bitmap over 25
// slots = 375299968947541) plus 8 trailing !eco.value roots: a loop over all 33 operands
// shifts the bitmap by 2*i up to 64 (UB; on x86 a shift of 64 re-reads slot 0 and
// reports a spurious "has kind=Int" on root 7).

module {
  func.func @target(%a0: i64, %a1: i64, %a2: i64, %a3: i64, %a4: i64, %a5: i64, %a6: i64, %a7: i64, %a8: i64, %a9: i64, %a10: i64, %a11: i64, %a12: i64, %a13: i64, %a14: i64, %a15: i64, %a16: i64, %a17: i64, %a18: i64, %a19: i64, %a20: i64, %a21: i64, %a22: i64, %a23: i64, %a24: i64, %a25: i64) -> i64 {
    eco.return %a0 : i64
  }

  func.func @pap_with_roots(%c0: i64, %c1: i64, %c2: i64, %c3: i64, %c4: i64, %c5: i64, %c6: i64, %c7: i64, %c8: i64, %c9: i64, %c10: i64, %c11: i64, %c12: i64, %c13: i64, %c14: i64, %c15: i64, %c16: i64, %c17: i64, %c18: i64, %c19: i64, %c20: i64, %c21: i64, %c22: i64, %c23: i64, %c24: i64, %r0: !eco.value, %r1: !eco.value, %r2: !eco.value, %r3: !eco.value, %r4: !eco.value, %r5: !eco.value, %r6: !eco.value, %r7: !eco.value) -> !eco.value {
    %pap = "eco.papCreate"(%c0, %c1, %c2, %c3, %c4, %c5, %c6, %c7, %c8, %c9, %c10, %c11, %c12, %c13, %c14, %c15, %c16, %c17, %c18, %c19, %c20, %c21, %c22, %c23, %c24, %r0, %r1, %r2, %r3, %r4, %r5, %r6, %r7) {
      function = @target,
      arity = 26 : i64,
      num_captured = 25 : i64,
      slot_kinds = array<i8: 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1>,
      eco.gc_roots_count = 8 : i64
    } : (i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value) -> !eco.value
    eco.return %pap : !eco.value
  }
}

// CHECK: eco.papCreate
// CHECK-NOT: error
