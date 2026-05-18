// RUN: %ecoc %s -emit=mlir-llvm -enable-unboxed-agg 2>&1 | %FileCheck %s
//
// Phase 3.3 (customMaxFields widening): a five-field single-ctor
// custom flows through cross-spec. Pre-widening this hit the cap=3
// gate and fell back to `value`, blocking specialisation; at the new
// cap of 8 the custom keeps its full shape and gets a worker.

module {
  func.func @first_of_five(%c: !eco.value) -> i64
      attributes {
          eco.logical_param_types = ["custom:7:5:i:i:i:i:i"],
          eco.logical_result_types = ["i64"]
      } {
    %v = eco.project.custom %c[0] : !eco.value -> i64
    return %v : i64
  }
}

// Wide-custom worker exists; flattened signature carries 5 i64
// fields. Wrapper preserves the boxed ABI:
// CHECK-DAG: llvm.func @first_of_five$unboxed
// CHECK-DAG: llvm.func @first_of_five(
