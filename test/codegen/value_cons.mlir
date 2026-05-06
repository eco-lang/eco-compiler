// RUN: %ecoc %s -emit=mlir-llvm 2>&1 | %FileCheck %s
//
// Phase 0: eco.make.cons + project.list_head/tail over a value-level
// cons whose tail is the embedded Nil constant.

module {
  func.func @value_cons_head(%head: i64) -> i64 {
    %nil = eco.constant Nil : !eco.value
    %c = eco.make.cons %head, %nil : (i64, !eco.value) -> !eco.cons<i64, !eco.value>
    %h = eco.project.list_head %c : !eco.cons<i64, !eco.value> -> i64
    return %h : i64
  }

  func.func @value_cons_tail(%head: !eco.value, %tail: !eco.value) -> !eco.value {
    %c = eco.make.cons %head, %tail : (!eco.value, !eco.value) -> !eco.cons<!eco.value, !eco.value>
    %t = eco.project.list_tail %c : !eco.cons<!eco.value, !eco.value> -> !eco.value
    return %t : !eco.value
  }
}

// CHECK: llvm.func @value_cons_head
// CHECK: llvm.mlir.undef : !llvm.struct<(i64, ptr<1>)>
// CHECK: llvm.insertvalue
// CHECK: llvm.extractvalue
//
// CHECK: llvm.func @value_cons_tail
// CHECK: llvm.mlir.undef : !llvm.struct<(ptr<1>, ptr<1>)>
//
// CHECK-NOT: eco_alloc_cons
// CHECK-NOT: eco_cons_head_i64
