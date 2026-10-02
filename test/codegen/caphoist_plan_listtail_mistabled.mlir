// RUN: not %ecoc %s -emit=llvm 2>&1 | %FileCheck %s
// UNSETENV: ECO_CAPHOIST_VALIDATE
//
// plans/mlir-split-backend-01-cap-hoist-plan.md fixture (c): a plan that
// (wrongly) covers a function holding a list-tail marker. The marker expands
// to eco_list_tail_hybrid, which can GC, so the backend's local verification
// (§4.3, on the POST-expansion IR) must refuse the plan instead of letting
// the covered function bump unchecked across a safepoint.
//
// CHECK: plan verification failed for covered function 'f': non-transparent call

module {
  llvm.module_flags [#llvm.mlir.module_flag<warning, "eco-cap-plan", "v1;K=512;m2=1;cw=0;veq=0">]
  llvm.func @__eco_alloc_inline(i64) -> !llvm.ptr<1> attributes {passthrough = ["gc-leaf-function"]}
  llvm.func @__eco_list_tail_inline(!llvm.ptr<1>) -> !llvm.ptr<1> attributes {passthrough = ["gc-leaf-function"]}
  llvm.func internal @f(%l: !llvm.ptr<1>) -> !llvm.ptr<1> attributes {passthrough = ["eco-cap-covered", ["eco-cap-budget", "16"]]} {
    %c16 = llvm.mlir.constant(16 : i64) : i64
    %a = llvm.call @__eco_alloc_inline(%c16) : (i64) -> !llvm.ptr<1>
    %t = llvm.call @__eco_list_tail_inline(%l) : (!llvm.ptr<1>) -> !llvm.ptr<1>
    llvm.return %t : !llvm.ptr<1>
  }
  func.func @main() -> i64 {
    %z = arith.constant 0 : i64
    return %z : i64
  }
}
