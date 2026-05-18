// RUN: %ecoc %s -emit=mlir-llvm -enable-unboxed-agg 2>&1 | %FileCheck %s
//
// Phase 3.1 #1 (logical-type attribute coverage): the cross-spec parser
// must accept "custom:..." and "cons:..." shape strings introduced in
// Phase 3.1 #1 even though they aren't promoted to real aggregate kinds
// yet (Phase 3.1 #2 will). Mixing them with an eligible "tuple2:i:i"
// param must not block specialization of the tuple param — the
// unhandled-yet shapes should be silently demoted to Boxed.

module {
  func.func @sum_with_extras(%t: !eco.value, %c: !eco.value, %lst: !eco.value) -> i64
      attributes {
          eco.logical_param_types = ["tuple2:i:i", "custom:7:2:i:v", "cons:i:v"],
          eco.logical_result_types = ["i64"]
      } {
    %a = eco.project.tuple2 %t[0] : !eco.value -> i64
    %b = eco.project.tuple2 %t[1] : !eco.value -> i64
    %s = arith.addi %a, %b : i64
    return %s : i64
  }
}

// The worker exists with an aggregate first param (tuple2 specialized)
// and the other two params left as `ptr addrspace(1)` (Custom/Cons
// stay boxed in Phase 3.1 #1):
// CHECK: llvm.func @sum_with_extras$unboxed
// CHECK-SAME: !llvm.struct<(i64, i64)>
// CHECK-SAME: ptr addrspace(1)
// CHECK-SAME: ptr addrspace(1)
//
// Wrapper exists, unboxes via eco_resolve_hptr:
// CHECK: llvm.func @sum_with_extras(
// CHECK: llvm.call @eco_resolve_hptr
