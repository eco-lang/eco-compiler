// RUN: %ecoc %s -emit=mlir-llvm -enable-unboxed-agg 2>&1 | %FileCheck %s
//
// Phase 3 Step 3: a function with `eco.logical_param_types = ["tuple2:i:i"]`
// and result `i64` is split into:
//   - `@add_pair` — wrapper with original ABI, uses eco_resolve_hptr +
//     load + insertvalue to convert the boxed param to a struct, then
//     calls @add_pair$unboxed.
//   - `@add_pair$unboxed` — worker taking `!eco.tuple2<i64, i64>` lowered
//     to `!llvm.struct<(i64, i64)>`; body uses extractvalue on the struct
//     param (no eco_resolve_hptr — the value-aggregate path bypasses the
//     heap).

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

// Both functions exist in the lowered output:
// CHECK: llvm.func @add_pair(
// CHECK: llvm.func @add_pair$unboxed(

// The wrapper resolves the HPointer (from_heap lowering):
// CHECK: llvm.call @eco_resolve_hptr

// The worker takes a struct value:
// CHECK: !llvm.struct<(i64, i64)>
// CHECK: llvm.extractvalue
