// RUN: %ecoc %s -emit=mlir-llvm 2>&1 | %FileCheck %s
//
// Phase 0: eco.to_heap on a !eco.tuple3 lowers to eco_alloc_tuple3.

module {
  func.func @value_to_heap_tuple3(%a: i64, %b: f64, %c: !eco.value) -> !eco.value {
    %t = eco.make.tuple3 %a, %b, %c
       : (i64, f64, !eco.value) -> !eco.tuple3<i64, f64, !eco.value>
    %h = eco.to_heap %t : (!eco.tuple3<i64, f64, !eco.value>) -> !eco.value
    return %h : !eco.value
  }
}

// CHECK: llvm.func @value_to_heap_tuple3
// CHECK: llvm.call @eco_alloc_tuple3
