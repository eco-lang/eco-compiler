// RUN: %ecoc %s -emit=llvm -enable-unboxed-agg 2>&1 | %FileCheck %s
//
// Phase 3.2 #2 LLVM-IR validation: verify that, after the full
// MLIR→LLVM→addEcoGCPipeline (mem2reg → SROA → FoldExtractValue →
// RewriteStatepointsForGC) pipeline, the worker function's
// parameter boundary is fully scalarised — no leftover FCA struct
// at the function signature, no insertvalue/extractvalue/alloca
// over the boundary struct. This is the empirical confirmation that
// SROA actually folds the Phase 0 make/project chains, not just
// that the MLIR-level types look right.
//
// Input is structurally identical to cross_spec_tuple2_pass.mlir;
// only the emit mode differs.

module {
  func.func @add_pair(%p: !eco.value) -> i64
      attributes {
          eco.logical_param_types = ["tuple2:i:i"],
          eco.logical_result_types = ["i64"]
      } {
    %a = eco.project.tuple2 %p[0] : !eco.value -> i64
    %b = eco.project.tuple2 %p[1] : !eco.value -> i64
    %s = arith.addi %a, %b : i64
    return %s : i64
  }
}

// Worker has fully scalar signature — no FCA struct at the boundary:
// CHECK: define i64 @"add_pair$unboxed"(i64 %0, i64 %1)
//
// Wrapper preserves the original boxed ABI and resolves the HPointer
// before threading scalars into the worker's statepoint:
// CHECK: define i64 @add_pair(ptr addrspace(1)
// CHECK: call ptr @eco_resolve_hptr
//
// No FCA struct artifacts survived SROA anywhere in the module:
// CHECK-NOT: insertvalue
// CHECK-NOT: extractvalue
// CHECK-NOT: alloca
