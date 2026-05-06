// RUN: %ecoc %s -emit=mlir-llvm 2>&1 | %FileCheck %s
//
// Phase 0: eco.make.custom with a tag attribute, project a field.
// Tag is structural (op attribute), never embedded in the type.

module {
  func.func @value_custom_just(%inner: !eco.value) -> !eco.value {
    %c = eco.make.custom(%inner) {tag = 1 : i64, constructor = "Just"}
       : (!eco.value) -> !eco.custom<!eco.value>
    %v = eco.project.custom %c[0] : !eco.custom<!eco.value> -> !eco.value
    return %v : !eco.value
  }
}

// CHECK: llvm.func @value_custom_just
// CHECK: llvm.mlir.undef : !llvm.struct<(ptr<1>)>
// CHECK: llvm.insertvalue
// CHECK: llvm.extractvalue
//
// CHECK-NOT: eco_alloc_custom
// CHECK-NOT: eco_resolve_hptr
