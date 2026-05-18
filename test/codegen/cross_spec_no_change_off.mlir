// RUN: %ecoc %s -emit=mlir-llvm 2>&1 | %FileCheck %s
//
// Phase 3.1 gate verification: with the cross-spec flag OFF (note the
// absence of `-enable-unboxed-agg`), the EcoUnboxedAggCrossSpec and
// EcoFlattenAggBoundary passes must not run. Input is structurally
// identical to cross_spec_tuple2_pass.mlir, which DOES produce a
// worker when the flag is on; assert the inverse here.
//
// Catches the regression class "pass scheduled unconditionally" — a
// future commit that moves the pass outside the opts.enableUnboxedAgg
// guard would slip past every existing flag-ON fixture.

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

// The function survives unchanged with the boxed ABI:
// CHECK: llvm.func @add_pair(
//
// No worker, no boundary helpers, no flatten marker:
// CHECK-NOT: $unboxed
// CHECK-NOT: eco.flattened_boundary
// CHECK-NOT: eco.unboxed_worker
