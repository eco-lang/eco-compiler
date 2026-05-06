// RUN: %ecoc %s -emit=mlir-llvm -enable-unboxed-agg 2>&1 | %FileCheck %s
//
// Phase 2: a Custom ADT built and immediately projected, never escaping
// the function, gets rewritten to eco.make.custom (with the structural
// `tag` attribute carried over). Heap layout is not produced.

module {
  func.func @local_custom_just(%inner: !eco.value) -> !eco.value {
    %c = eco.construct.custom(%inner) {tag = 1 : i64, size = 1 : i64, unboxed_bitmap = 0 : i64, constructor = "Just"}
       : (!eco.value) -> !eco.value
    %v = eco.project.custom %c[0] : !eco.value -> !eco.value
    return %v : !eco.value
  }
}

// CHECK: llvm.func @local_custom_just
// CHECK: llvm.mlir.undef : !llvm.struct<(ptr<1>)>
// CHECK: llvm.insertvalue
// CHECK: llvm.extractvalue
//
// CHECK-NOT: eco_alloc_custom
// CHECK-NOT: eco_resolve_hptr
