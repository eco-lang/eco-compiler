// RUN: %ecoc %s -emit=mlir-llvm 2>&1 | %FileCheck %s
//
// B15 (plans/wide-object-tail-kind-words-phase-1.md step 1b.7): papCreateGroup
// registers its flat captures array as GC root ranges of at most 64 slots each
// (eco_gc_push_stack_range asserts count <= 64; one 64-bit mask per range). Three
// siblings x 25 boxed captures = 75 captures => two ranges: [0, 64) and [64, 75),
// each with an all-boxed mask; one restore pops both.

module {
  llvm.func @"s0$clo"(%a: !llvm.ptr) -> !llvm.ptr {
    %r = llvm.mlir.zero : !llvm.ptr
    llvm.return %r : !llvm.ptr
  }
  func.func @"s0$cap"(%p0: !eco.value, %p1: !eco.value, %p2: !eco.value, %p3: !eco.value, %p4: !eco.value, %p5: !eco.value, %p6: !eco.value, %p7: !eco.value, %p8: !eco.value, %p9: !eco.value, %p10: !eco.value, %p11: !eco.value, %p12: !eco.value, %p13: !eco.value, %p14: !eco.value, %p15: !eco.value, %p16: !eco.value, %p17: !eco.value, %p18: !eco.value, %p19: !eco.value, %p20: !eco.value, %p21: !eco.value, %p22: !eco.value, %p23: !eco.value, %p24: !eco.value, %p25: !eco.value) -> !eco.value {
    eco.return %p25 : !eco.value
  }
  llvm.func @"s1$clo"(%a: !llvm.ptr) -> !llvm.ptr {
    %r = llvm.mlir.zero : !llvm.ptr
    llvm.return %r : !llvm.ptr
  }
  func.func @"s1$cap"(%p0: !eco.value, %p1: !eco.value, %p2: !eco.value, %p3: !eco.value, %p4: !eco.value, %p5: !eco.value, %p6: !eco.value, %p7: !eco.value, %p8: !eco.value, %p9: !eco.value, %p10: !eco.value, %p11: !eco.value, %p12: !eco.value, %p13: !eco.value, %p14: !eco.value, %p15: !eco.value, %p16: !eco.value, %p17: !eco.value, %p18: !eco.value, %p19: !eco.value, %p20: !eco.value, %p21: !eco.value, %p22: !eco.value, %p23: !eco.value, %p24: !eco.value, %p25: !eco.value) -> !eco.value {
    eco.return %p25 : !eco.value
  }
  llvm.func @"s2$clo"(%a: !llvm.ptr) -> !llvm.ptr {
    %r = llvm.mlir.zero : !llvm.ptr
    llvm.return %r : !llvm.ptr
  }
  func.func @"s2$cap"(%p0: !eco.value, %p1: !eco.value, %p2: !eco.value, %p3: !eco.value, %p4: !eco.value, %p5: !eco.value, %p6: !eco.value, %p7: !eco.value, %p8: !eco.value, %p9: !eco.value, %p10: !eco.value, %p11: !eco.value, %p12: !eco.value, %p13: !eco.value, %p14: !eco.value, %p15: !eco.value, %p16: !eco.value, %p17: !eco.value, %p18: !eco.value, %p19: !eco.value, %p20: !eco.value, %p21: !eco.value, %p22: !eco.value, %p23: !eco.value, %p24: !eco.value, %p25: !eco.value) -> !eco.value {
    eco.return %p25 : !eco.value
  }

  func.func @group75(%v0: !eco.value, %v1: !eco.value, %v2: !eco.value, %v3: !eco.value, %v4: !eco.value, %v5: !eco.value, %v6: !eco.value, %v7: !eco.value, %v8: !eco.value, %v9: !eco.value, %v10: !eco.value, %v11: !eco.value, %v12: !eco.value, %v13: !eco.value, %v14: !eco.value, %v15: !eco.value, %v16: !eco.value, %v17: !eco.value, %v18: !eco.value, %v19: !eco.value, %v20: !eco.value, %v21: !eco.value, %v22: !eco.value, %v23: !eco.value, %v24: !eco.value, %v25: !eco.value, %v26: !eco.value, %v27: !eco.value, %v28: !eco.value, %v29: !eco.value, %v30: !eco.value, %v31: !eco.value, %v32: !eco.value, %v33: !eco.value, %v34: !eco.value, %v35: !eco.value, %v36: !eco.value, %v37: !eco.value, %v38: !eco.value, %v39: !eco.value, %v40: !eco.value, %v41: !eco.value, %v42: !eco.value, %v43: !eco.value, %v44: !eco.value, %v45: !eco.value, %v46: !eco.value, %v47: !eco.value, %v48: !eco.value, %v49: !eco.value, %v50: !eco.value, %v51: !eco.value, %v52: !eco.value, %v53: !eco.value, %v54: !eco.value, %v55: !eco.value, %v56: !eco.value, %v57: !eco.value, %v58: !eco.value, %v59: !eco.value, %v60: !eco.value, %v61: !eco.value, %v62: !eco.value, %v63: !eco.value, %v64: !eco.value, %v65: !eco.value, %v66: !eco.value, %v67: !eco.value, %v68: !eco.value, %v69: !eco.value, %v70: !eco.value, %v71: !eco.value, %v72: !eco.value, %v73: !eco.value, %v74: !eco.value) -> !eco.value {
    %c:3 = "eco.papCreateGroup"(%v0, %v1, %v2, %v3, %v4, %v5, %v6, %v7, %v8, %v9, %v10, %v11, %v12, %v13, %v14, %v15, %v16, %v17, %v18, %v19, %v20, %v21, %v22, %v23, %v24, %v25, %v26, %v27, %v28, %v29, %v30, %v31, %v32, %v33, %v34, %v35, %v36, %v37, %v38, %v39, %v40, %v41, %v42, %v43, %v44, %v45, %v46, %v47, %v48, %v49, %v50, %v51, %v52, %v53, %v54, %v55, %v56, %v57, %v58, %v59, %v60, %v61, %v62, %v63, %v64, %v65, %v66, %v67, %v68, %v69, %v70, %v71, %v72, %v73, %v74) {
      functions = [@"s0$clo", @"s1$clo", @"s2$clo"],
      fast_evaluators = [@"s0$cap", @"s1$cap", @"s2$cap"],
      arities = [26, 26, 26],
      num_captured = [25, 25, 25],
      unboxed_bitmaps = [0, 0, 0],
      capture_counts = [25, 25, 25],
      cross_edges = []
    } : (!eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value) -> (!eco.value, !eco.value, !eco.value)
    eco.return %c#2 : !eco.value
  }
}

// The fixture harness is order-insensitive, so each range is pinned as one
// CHECK-NEXT chain. Before the fix: one range of count 75 (mask -1 loses 64..74).
// CHECK-LABEL: llvm.func @group75
// CHECK: llvm.call @eco_gc_stack_range_point
// CHECK-NEXT: llvm.mlir.constant(64 : i64)
// CHECK-NEXT: llvm.mlir.constant(-1 : i64)
// CHECK-NEXT: llvm.call @eco_gc_push_stack_range
// CHECK-NEXT: llvm.mlir.constant(64 : i64)
// CHECK-NEXT: llvm.getelementptr
// CHECK-NEXT: llvm.mlir.constant(11 : i64)
// CHECK-NEXT: llvm.mlir.constant(2047 : i64)
// CHECK-NEXT: llvm.call @eco_gc_push_stack_range
// CHECK: llvm.call @eco_alloc_closure_group_l
// CHECK: llvm.call @eco_gc_restore_stack_range_point
