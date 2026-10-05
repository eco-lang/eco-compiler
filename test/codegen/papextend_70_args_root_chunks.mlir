// RUN: %ecoc %s -emit=mlir-llvm 2>&1 | %FileCheck %s
//
// Phase 2 (plans/wide-object-tail-kind-words-phase-2.md 2.2/2.7, B23): an under-saturated
// papExtend with 70 boxed newargs. eco_gc_push_stack_range asserts count <= 64, so the
// args buffer is rooted in two chunks: 64 slots (mask -1), then 6 slots at +64 (mask 63).
// The extend calls eco_pap_extend_l with an EvalParamLayout of the 70 caller kinds.

module {
  func.func @take80(%p0: !eco.value, %p1: !eco.value, %p2: !eco.value, %p3: !eco.value, %p4: !eco.value, %p5: !eco.value, %p6: !eco.value, %p7: !eco.value, %p8: !eco.value, %p9: !eco.value, %p10: !eco.value, %p11: !eco.value, %p12: !eco.value, %p13: !eco.value, %p14: !eco.value, %p15: !eco.value, %p16: !eco.value, %p17: !eco.value, %p18: !eco.value, %p19: !eco.value, %p20: !eco.value, %p21: !eco.value, %p22: !eco.value, %p23: !eco.value, %p24: !eco.value, %p25: !eco.value, %p26: !eco.value, %p27: !eco.value, %p28: !eco.value, %p29: !eco.value, %p30: !eco.value, %p31: !eco.value, %p32: !eco.value, %p33: !eco.value, %p34: !eco.value, %p35: !eco.value, %p36: !eco.value, %p37: !eco.value, %p38: !eco.value, %p39: !eco.value, %p40: !eco.value, %p41: !eco.value, %p42: !eco.value, %p43: !eco.value, %p44: !eco.value, %p45: !eco.value, %p46: !eco.value, %p47: !eco.value, %p48: !eco.value, %p49: !eco.value, %p50: !eco.value, %p51: !eco.value, %p52: !eco.value, %p53: !eco.value, %p54: !eco.value, %p55: !eco.value, %p56: !eco.value, %p57: !eco.value, %p58: !eco.value, %p59: !eco.value, %p60: !eco.value, %p61: !eco.value, %p62: !eco.value, %p63: !eco.value, %p64: !eco.value, %p65: !eco.value, %p66: !eco.value, %p67: !eco.value, %p68: !eco.value, %p69: !eco.value, %p70: !eco.value, %p71: !eco.value, %p72: !eco.value, %p73: !eco.value, %p74: !eco.value, %p75: !eco.value, %p76: !eco.value, %p77: !eco.value, %p78: !eco.value, %p79: !eco.value) -> !eco.value {
    eco.return %p0 : !eco.value
  }

  func.func @extend70(%f: !eco.value, %v0: !eco.value, %v1: !eco.value, %v2: !eco.value, %v3: !eco.value, %v4: !eco.value, %v5: !eco.value, %v6: !eco.value, %v7: !eco.value, %v8: !eco.value, %v9: !eco.value, %v10: !eco.value, %v11: !eco.value, %v12: !eco.value, %v13: !eco.value, %v14: !eco.value, %v15: !eco.value, %v16: !eco.value, %v17: !eco.value, %v18: !eco.value, %v19: !eco.value, %v20: !eco.value, %v21: !eco.value, %v22: !eco.value, %v23: !eco.value, %v24: !eco.value, %v25: !eco.value, %v26: !eco.value, %v27: !eco.value, %v28: !eco.value, %v29: !eco.value, %v30: !eco.value, %v31: !eco.value, %v32: !eco.value, %v33: !eco.value, %v34: !eco.value, %v35: !eco.value, %v36: !eco.value, %v37: !eco.value, %v38: !eco.value, %v39: !eco.value, %v40: !eco.value, %v41: !eco.value, %v42: !eco.value, %v43: !eco.value, %v44: !eco.value, %v45: !eco.value, %v46: !eco.value, %v47: !eco.value, %v48: !eco.value, %v49: !eco.value, %v50: !eco.value, %v51: !eco.value, %v52: !eco.value, %v53: !eco.value, %v54: !eco.value, %v55: !eco.value, %v56: !eco.value, %v57: !eco.value, %v58: !eco.value, %v59: !eco.value, %v60: !eco.value, %v61: !eco.value, %v62: !eco.value, %v63: !eco.value, %v64: !eco.value, %v65: !eco.value, %v66: !eco.value, %v67: !eco.value, %v68: !eco.value, %v69: !eco.value) -> !eco.value {
    %p = "eco.papExtend"(%f, %v0, %v1, %v2, %v3, %v4, %v5, %v6, %v7, %v8, %v9, %v10, %v11, %v12, %v13, %v14, %v15, %v16, %v17, %v18, %v19, %v20, %v21, %v22, %v23, %v24, %v25, %v26, %v27, %v28, %v29, %v30, %v31, %v32, %v33, %v34, %v35, %v36, %v37, %v38, %v39, %v40, %v41, %v42, %v43, %v44, %v45, %v46, %v47, %v48, %v49, %v50, %v51, %v52, %v53, %v54, %v55, %v56, %v57, %v58, %v59, %v60, %v61, %v62, %v63, %v64, %v65, %v66, %v67, %v68, %v69) {
      remaining_arity = 80 : i64
    } : (!eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value) -> !eco.value
    eco.return %p : !eco.value
  }
}

// CHECK: llvm.func @extend70
// CHECK: llvm.mlir.constant(64 : i64)
// CHECK-NEXT: llvm.mlir.constant(-1 : i64)
// CHECK-NEXT: llvm.call @eco_gc_push_stack_range
// CHECK: llvm.getelementptr
// CHECK-NEXT: llvm.mlir.constant(6 : i64)
// CHECK-NEXT: llvm.mlir.constant(63 : i64)
// CHECK-NEXT: llvm.call @eco_gc_push_stack_range
// CHECK: llvm.mlir.addressof @__eco_eval_layout_r0_h{{[0-9a-f]+}}_70
// CHECK: llvm.call @eco_pap_extend_l
// CHECK-NOT: @eco_pap_extend(
