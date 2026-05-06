// RUN: %ecoc %s -emit=mlir-llvm 2>&1 | %FileCheck %s
//
// Phase 0: eco.make.tuple3 + project.tuple3, mixed unboxed/boxed elements.

module {
  func.func @value_tuple3_third(%a: i64, %b: f64, %c: !eco.value) -> !eco.value {
    %t = eco.make.tuple3 %a, %b, %c : (i64, f64, !eco.value) -> !eco.tuple3<i64, f64, !eco.value>
    %x = eco.project.tuple3 %t[2] : !eco.tuple3<i64, f64, !eco.value> -> !eco.value
    return %x : !eco.value
  }
}

// CHECK: llvm.func @value_tuple3_third
// CHECK: llvm.mlir.undef : !llvm.struct<(i64, f64, ptr<1>)>
// CHECK: llvm.insertvalue
// CHECK: llvm.extractvalue
//
// CHECK-NOT: eco_alloc_tuple3
// CHECK-NOT: eco_resolve_hptr
