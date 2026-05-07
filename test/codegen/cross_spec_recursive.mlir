// RUN: %ecoc %s -emit=mlir-llvm -enable-unboxed-agg 2>&1 | %FileCheck %s
//
// Phase 3 Step 4 (recursion): a self-recursive function whose aggregate
// param is used both for projection and for recursive self-call must:
//   1. Be specialised (the param is "purely projecting" in v1's sense
//      because the only non-projection use is a recursive self-call,
//      which we explicitly allow).
//   2. Have its recursive self-call inside the worker rewritten to call
//      `@sum_pair$unboxed` directly, with the aggregate-typed operand
//      threaded through (no re-boxing).

module {
  func.func @sum_pair(%p: !eco.value, %n: i64) -> i64
      attributes {
          eco.logical_param_types = ["tuple2:i:i", "i64"],
          eco.logical_result_types = ["i64"]
      } {
    %zero = arith.constant 0 : i64
    %is_zero = arith.cmpi eq, %n, %zero : i64
    %one = arith.constant 1 : i64
    %nm1 = arith.subi %n, %one : i64
    %a = eco.project.tuple2 %p[0] : !eco.value -> i64
    %b = eco.project.tuple2 %p[1] : !eco.value -> i64
    %s = arith.addi %a, %b : i64
    %rec = "eco.call"(%p, %nm1) {callee = @sum_pair}
        : (!eco.value, i64) -> i64
    %r = arith.select %is_zero, %s, %rec : i64
    return %r : i64
  }
}

// Worker exists with aggregate param:
// CHECK: llvm.func @sum_pair$unboxed
// CHECK: !llvm.struct<(i64, i64)>
//
// Worker body's recursive call goes to @sum_pair$unboxed (not the wrapper):
// CHECK: llvm.call @sum_pair$unboxed
//
// Wrapper exists, resolves the HPointer:
// CHECK: llvm.func @sum_pair(
// CHECK: llvm.call @eco_resolve_hptr
