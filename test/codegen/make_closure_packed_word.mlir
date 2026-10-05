// RUN: %ecoc %s -emit=mlir-llvm 2>&1 | %FileCheck %s
//
// B13 (plans/wide-object-tail-kind-words-phase-0.md): eco.make.closure must pack the
// closure word exactly like papCreate: n_values | max_values<<6 | result_kind<<12 |
// kinds<<14 (Phase 1 layout). Captures (i64, !eco.value), arity 3, legacy (untyped)
// evaluator, so the kinds are the capture kinds: slot 0 = Int (1), slot 1 = boxed.
// Expected word: 2 | 3<<6 | 0<<12 | 1<<14 = 16578.

module {
  llvm.func @stub_evaluator(%args: !llvm.ptr) -> !llvm.ptr {
    %r = llvm.mlir.zero : !llvm.ptr
    llvm.return %r : !llvm.ptr
  }

  func.func @make_closure_packed(%cap0: i64, %cap1: !eco.value) -> !eco.value {
    %env = eco.make.closure_env(%cap0, %cap1)
         : (i64, !eco.value) -> !eco.closure_env<i64, !eco.value>
    %clo = eco.make.closure @stub_evaluator, %env {arity = 3 : i64}
         : (!eco.closure_env<i64, !eco.value>) -> !eco.value
    return %clo : !eco.value
  }

  func.func @make_closure_rk1(%cap0: i64, %cap1: !eco.value) -> !eco.value {
    %env = eco.make.closure_env(%cap0, %cap1)
         : (i64, !eco.value) -> !eco.closure_env<i64, !eco.value>
    %clo = eco.make.closure @stub_evaluator, %env {arity = 3 : i64, _result_kind = 1 : i8}
         : (!eco.closure_env<i64, !eco.value>) -> !eco.value
    return %clo : !eco.value
  }
}

// CHECK-LABEL: llvm.func @make_closure_packed
// CHECK: llvm.mlir.constant(16578 : i64)

// rk=1: 16578 | 1<<12 = 20674
// CHECK-LABEL: llvm.func @make_closure_rk1
// CHECK: llvm.mlir.constant(20674 : i64)
