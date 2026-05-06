// RUN: %ecoc %s -emit=mlir-llvm 2>&1 | %FileCheck %s
//
// Phase 0: eco.make.closure_env + project.closure on a value-level env.
// The parallel ProjectClosureFromEnvLowering pattern fires for the
// !eco.closure_env operand; the heap-side closure pattern is untouched.

module {
  func.func @value_closure_env_pick_int(%a: i64, %b: !eco.value) -> i64 {
    %env = eco.make.closure_env(%a, %b)
         : (i64, !eco.value) -> !eco.closure_env<i64, !eco.value>
    %v = "eco.project.closure"(%env) {index = 0 : i64, is_unboxed = true}
       : (!eco.closure_env<i64, !eco.value>) -> i64
    return %v : i64
  }

  func.func @value_closure_env_pick_box(%a: i64, %b: !eco.value) -> !eco.value {
    %env = eco.make.closure_env(%a, %b)
         : (i64, !eco.value) -> !eco.closure_env<i64, !eco.value>
    %v = "eco.project.closure"(%env) {index = 1 : i64}
       : (!eco.closure_env<i64, !eco.value>) -> !eco.value
    return %v : !eco.value
  }
}

// CHECK: llvm.func @value_closure_env_pick_int
// CHECK: llvm.mlir.undef : !llvm.struct<(i64, ptr<1>)>
// CHECK: llvm.insertvalue
// CHECK: llvm.extractvalue
//
// CHECK: llvm.func @value_closure_env_pick_box
// CHECK: llvm.extractvalue
//
// CHECK-NOT: eco_alloc_closure
// CHECK-NOT: eco_resolve_hptr
