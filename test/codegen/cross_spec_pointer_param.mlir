// RUN: %ecoc %s -emit=mlir-llvm -enable-unboxed-agg 2>&1 | %FileCheck %s
//
// Phase 3.1 #3 (boundary flattening): a function with a tuple2
// parameter carrying an !eco.value element passes the FCA-unimplemented
// constraint because EcoFlattenAggBoundary scalarises the function
// signature before RS4GC runs. The worker is invoked with individual
// (i64, ptr addrspace(1)) operands at the LLVM level, never as a
// pass-by-value struct containing a GC pointer.
//
// Test shape: `f : (Int, a) -> Int` where `a` stays boxed (`!eco.value`).
// The body reads only the integer first slot, but the second slot's
// presence forces the pre-3.1 all-primitive guard to demote the
// aggregate — verifying that the guard has been lifted.

module {
  func.func @sum_int_with_extra(%t: !eco.value) -> i64
      attributes {
          eco.logical_param_types = ["tuple2:i:v"],
          eco.logical_result_types = ["i64"]
      } {
    %a = eco.project.tuple2 %t[0] : !eco.value -> i64
    return %a : i64
  }
}

// Worker exists with the flattened signature: an i64 and a ptr<1>,
// never an FCA struct at the boundary.
// CHECK: llvm.func @sum_int_with_extra$unboxed
// CHECK-SAME: i64
// CHECK-SAME: ptr addrspace(1)
//
// Wrapper exists and unboxes via eco_resolve_hptr to read the
// individual fields it forwards to the worker:
// CHECK: llvm.func @sum_int_with_extra(
// CHECK: llvm.call @eco_resolve_hptr
