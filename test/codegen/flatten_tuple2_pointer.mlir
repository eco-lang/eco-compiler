// RUN: %ecoc %s -emit=mlir-llvm -enable-unboxed-agg 2>&1 | %FileCheck %s
//
// Direct EcoFlattenAggBoundary test: a worker that already carries
// the eco.unboxed_worker attribute is skipped by EcoUnboxedAggCrossSpec
// (per its kUnboxedWorkerAttr guard) so only the flatten pass acts on
// it. The worker takes a !eco.tuple2<i64, !eco.value> param — the
// pointer-element case that's the whole point of dropping the
// pre-3.1 all-primitive FCA guard.
//
// After flatten:
//   - worker signature becomes (i64, !llvm.ptr<1>) → i64,
//   - the caller's func.call decomposes the tuple via project ops
//     before the call, threading scalars directly.

module {
  func.func private @sum$unboxed(%t: !eco.tuple2<i64, !eco.value>) -> i64
      attributes { eco.unboxed_worker } {
    %a = eco.project.tuple2 %t[0] : !eco.tuple2<i64, !eco.value> -> i64
    return %a : i64
  }

  func.func @caller(%x: i64, %p: !eco.value) -> i64 {
    %t = eco.make.tuple2 %x, %p
        : (i64, !eco.value) -> !eco.tuple2<i64, !eco.value>
    %r = func.call @sum$unboxed(%t)
        : (!eco.tuple2<i64, !eco.value>) -> i64
    return %r : i64
  }
}

// Worker boundary is scalarised — no struct at the LLVM signature:
// CHECK: llvm.func @sum$unboxed
// CHECK-SAME: i64
// CHECK-SAME: ptr addrspace(1)
// CHECK-SAME: -> i64
//
// Caller still has the original ABI; the call site decomposes via
// extractvalue (project lowered) and threads scalars to the worker:
// CHECK: llvm.func @caller
// CHECK: llvm.extractvalue
// CHECK: llvm.call @sum$unboxed
