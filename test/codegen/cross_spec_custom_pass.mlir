// RUN: %ecoc %s -emit=mlir-llvm -enable-unboxed-agg 2>&1 | %FileCheck %s
//
// Phase 3.1 #2: a function with a single-constructor Custom param
// (encoded as "custom:Tag:N:K0:...:KN-1") is split into wrapper/worker.
// The worker takes the value-level !eco.custom<i64, i64> aggregate
// (lowered to an LLVM struct), the wrapper unboxes via eco.from_heap.
//
// Test shape: a `type Box = Box Int Int` style custom with two i64
// fields. Tag = 0 (single ctor). The function sums the fields.

module {
  func.func @sum_box(%b: !eco.value) -> i64
      attributes {
          eco.logical_param_types = ["custom:0:2:i:i"],
          eco.logical_result_types = ["i64"]
      } {
    %a = eco.project.custom %b[0] : !eco.value -> i64
    %c = eco.project.custom %b[1] : !eco.value -> i64
    %s = arith.addi %a, %c : i64
    return %s : i64
  }
}

// Both functions exist:
// CHECK: llvm.func @sum_box(
// CHECK: llvm.func @sum_box$unboxed(
//
// The worker takes the value-aggregate struct value:
// CHECK: !llvm.struct<(i64, i64)>
// CHECK: llvm.extractvalue
//
// The wrapper unboxes via eco_resolve_hptr:
// CHECK: llvm.call @eco_resolve_hptr
