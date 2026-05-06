// RUN: %ecoc %s -emit=mlir-llvm 2>&1 | %FileCheck %s
//
// Phase 0: eco.make.record + project.record. 3-field record, mixed kinds.

module {
  func.func @value_record3_pick(%x: i64, %y: !eco.value, %z: f64) -> !eco.value {
    %r = eco.make.record(%x, %y, %z) : (i64, !eco.value, f64) -> !eco.record<i64, !eco.value, f64>
    %v = eco.project.record %r[1] : !eco.record<i64, !eco.value, f64> -> !eco.value
    return %v : !eco.value
  }
}

// CHECK: llvm.func @value_record3_pick
// CHECK: llvm.mlir.undef : !llvm.struct<(i64, ptr<1>, f64)>
// CHECK: llvm.insertvalue
// CHECK: llvm.extractvalue
//
// CHECK-NOT: eco_alloc_record
// CHECK-NOT: eco_resolve_hptr
