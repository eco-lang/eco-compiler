// RUN: %ecoc %s -emit=mlir-llvm -enable-unboxed-agg 2>&1 | %FileCheck %s
//
// Phase 2: a list cons cell built and immediately projected, never
// escaping the function, gets rewritten to eco.make.cons -> LLVM struct
// insert/extract. The tail stays !eco.value (Phase 0 plumbing
// constraint). Useful for the *tip* of a list pattern: build cons,
// project head/tail, discard.

module {
  func.func @local_cons_head(%head: !eco.value, %tail: !eco.value) -> !eco.value {
    %c = eco.construct.list %head, %tail : !eco.value, !eco.value -> !eco.value
    %h = eco.project.list_head %c : !eco.value -> !eco.value
    return %h : !eco.value
  }

  func.func @local_cons_tail(%head: !eco.value, %tail: !eco.value) -> !eco.value {
    %c = eco.construct.list %head, %tail : !eco.value, !eco.value -> !eco.value
    %t = eco.project.list_tail %c : !eco.value -> !eco.value
    return %t : !eco.value
  }
}

// CHECK: llvm.func @local_cons_head
// CHECK: llvm.mlir.undef : !llvm.struct<(ptr<1>, ptr<1>)>
// CHECK: llvm.insertvalue
// CHECK: llvm.extractvalue
//
// CHECK: llvm.func @local_cons_tail
// CHECK: llvm.mlir.undef : !llvm.struct<(ptr<1>, ptr<1>)>
//
// CHECK-NOT: eco_alloc_cons
// CHECK-NOT: eco_resolve_hptr
// CHECK-NOT: eco_cons_head
