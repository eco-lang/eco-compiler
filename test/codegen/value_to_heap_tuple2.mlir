// RUN: %ecoc %s -emit=mlir-llvm 2>&1 | %FileCheck %s
//
// Phase 0: eco.to_heap on a !eco.tuple2 lowers to eco_alloc_tuple2 with
// the same heap layout `eco.construct.tuple2` would produce.

module {
  func.func @value_to_heap_tuple2(%a: i64, %b: !eco.value) -> !eco.value {
    %t = eco.make.tuple2 %a, %b : (i64, !eco.value) -> !eco.tuple2<i64, !eco.value>
    %h = eco.to_heap %t : (!eco.tuple2<i64, !eco.value>) -> !eco.value
    return %h : !eco.value
  }
}

// CHECK: llvm.func @value_to_heap_tuple2
// CHECK: llvm.mlir.undef : !llvm.struct<(i64, ptr<1>)>
// CHECK: llvm.extractvalue
// CHECK: llvm.call @__eco_alloc_inline
