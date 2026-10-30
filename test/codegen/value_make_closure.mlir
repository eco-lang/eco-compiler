// RUN: %ecoc %s -emit=mlir-llvm 2>&1 | %FileCheck %s
// RUN: env ECO_FCA_SCAN=1 %ecoc %s -emit=llvm 2>&1 | %FileCheck %s --check-prefix=FCA
//
// Phase 0: eco.make.closure_env + eco.make.closure realises a heap
// closure with captures populated from the value-level env aggregate.
//
// FCA leg: an env built in the same function is folded away before RS4GC, so no aggregate holding a
// GC pointer survives (the control for make_closure_env_arg_fca.mlir, where it arrives as an
// argument).
// FCA: FCA-SCAN: clean

module {
  llvm.func @stub_evaluator(%args: !llvm.ptr) -> !llvm.ptr {
    %r = llvm.mlir.zero : !llvm.ptr
    llvm.return %r : !llvm.ptr
  }

  func.func @value_make_closure(%cap0: i64, %cap1: !eco.value) -> !eco.value {
    %env = eco.make.closure_env(%cap0, %cap1)
         : (i64, !eco.value) -> !eco.closure_env<i64, !eco.value>
    %clo = eco.make.closure @stub_evaluator, %env {arity = 3 : i64}
         : (!eco.closure_env<i64, !eco.value>) -> !eco.value
    return %clo : !eco.value
  }
}

// CHECK: llvm.func @value_make_closure
// CHECK: llvm.mlir.undef : !llvm.struct<(i64, ptr<1>)>
// CHECK: llvm.insertvalue
// CHECK: llvm.call @__eco_alloc_inline
// P2.5 R5 (plans/allocator-resolve-inlining.md): the closure is FRESH (no
// safepoint between alloc and stores), so there is no resolve and no
// forwarding diamond — stores go directly through the AS1 alloc result.
// CHECK-NOT: llvm.call @eco_resolve_hptr
// CHECK-NOT: llvm.call @__eco_resolve_fwd
// CHECK: llvm.extractvalue
// CHECK: llvm.store
