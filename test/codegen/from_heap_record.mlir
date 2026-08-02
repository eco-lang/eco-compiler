// RUN: %ecoc %s -emit=mlir-llvm 2>&1 | %FileCheck %s
//
// Phase 3: eco.from_heap on a record with a mixed bitmap (Int + Float)
// loads each field at the correct slot width — i64 directly, f64 via
// bitcast from the i64-wide slot.

module {
  func.func @from_heap_record(%hp: !eco.value) -> f64 {
    %r = eco.from_heap %hp : (!eco.value) -> !eco.record<i64, f64>
    %y = eco.project.record %r[1] : !eco.record<i64, f64> -> f64
    return %y : f64
  }
}

// CHECK: llvm.func @from_heap_record
// P2.5 (plans/allocator-resolve-inlining.md R4): the base resolves via the
// inline forwarding-check marker, not the out-of-line runtime call.
// CHECK: llvm.call @__eco_resolve_fwd
// CHECK-NOT: llvm.call @eco_resolve_hptr
// CHECK: llvm.bitcast
// CHECK: llvm.mlir.undef : !llvm.struct<(i64, f64)>
