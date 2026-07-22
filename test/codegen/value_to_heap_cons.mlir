// RUN: %ecoc %s -emit=mlir-llvm 2>&1 | %FileCheck %s
//
// Phase 0: eco.to_heap on a !eco.cons lowers to eco_alloc_cons.

module {
  func.func @value_to_heap_cons(%head: i64, %tail: !eco.value) -> !eco.value {
    %c = eco.make.cons %head, %tail : (i64, !eco.value) -> !eco.cons<i64, !eco.value>
    %h = eco.to_heap %c : (!eco.cons<i64, !eco.value>) -> !eco.value
    return %h : !eco.value
  }
}

// CHECK: llvm.func @value_to_heap_cons
// CHECK: llvm.call @__eco_alloc_inline
