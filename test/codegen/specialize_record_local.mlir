// RUN: %ecoc %s -emit=mlir-llvm -enable-unboxed-agg 2>&1 | %FileCheck %s
//
// Phase 2: a Record built and immediately projected, never escaping the
// function, gets rewritten by EcoEscapeAnalysisPass + EcoUnboxedAggSpecialize
// into eco.make.record -> LLVM struct insert/extract chain. Mixed
// element kinds (i64, !eco.value, f64).

module {
  func.func @local_record(%x: i64, %y: !eco.value, %z: f64) -> !eco.value {
    %r = eco.construct.record(%x, %y, %z) {field_count = 3 : i64, unboxed_bitmap = 0 : i64}
       : (i64, !eco.value, f64) -> !eco.value
    %v = eco.project.record %r[1] : !eco.value -> !eco.value
    return %v : !eco.value
  }
}

// CHECK: llvm.func @local_record
// CHECK: llvm.mlir.undef : !llvm.struct<(i64, ptr<1>, f64)>
// CHECK: llvm.insertvalue
// CHECK: llvm.extractvalue
//
// Heap allocation must NOT survive.
// CHECK-NOT: eco_alloc_record
// CHECK-NOT: eco_resolve_hptr
