// RUN: %ecoc %s -emit=mlir-llvm -enable-unboxed-agg 2>&1 | %FileCheck %s
//
// Phase 1: same idea for Tuple3, all primitive elements (i64, f64, i64).
// The rewrite preserves operand types in the aggregate result type so
// the projection still types-checks against the value-form operand
// constraint.

module {
  func.func @local_tuple3(%a: i64, %b: f64, %c: i64) -> f64 {
    %t = eco.construct.tuple3 %a, %b, %c : i64, f64, i64 -> !eco.value
    %x = eco.project.tuple3 %t[1] : !eco.value -> f64
    return %x : f64
  }
}

// CHECK: llvm.func @local_tuple3
// CHECK: llvm.mlir.undef : !llvm.struct<(i64, f64, i64)>
// CHECK: llvm.insertvalue
// CHECK: llvm.extractvalue
//
// CHECK-NOT: eco_alloc_tuple3
// CHECK-NOT: eco.construct.tuple3
