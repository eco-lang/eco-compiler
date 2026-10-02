// RUN: not %ecoc %s -emit=llvm 2>&1 | %FileCheck %s
// UNSETENV: ECO_CAPHOIST_VALIDATE
//
// plans/mlir-split-backend-01-cap-hoist-plan.md fixture (g): a covered
// function must have local linkage. An externally visible covered function
// could be called from code that emits no ensure for it (e.g. a closed-world
// plan applied to an object/shared-library output).
//
// CHECK: plan verification failed for covered function 'f': covered function without local linkage

module {
  llvm.module_flags [#llvm.mlir.module_flag<warning, "eco-cap-plan", "v1;K=512;m2=1;cw=0;veq=0">]
  llvm.func @__eco_alloc_inline(i64) -> !llvm.ptr<1> attributes {passthrough = ["gc-leaf-function"]}
  llvm.func @f() -> !llvm.ptr<1> attributes {passthrough = ["eco-cap-covered", ["eco-cap-budget", "16"]]} {
    %c16 = llvm.mlir.constant(16 : i64) : i64
    %a = llvm.call @__eco_alloc_inline(%c16) : (i64) -> !llvm.ptr<1>
    llvm.return %a : !llvm.ptr<1>
  }
  func.func @main() -> i64 {
    %z = arith.constant 0 : i64
    return %z : i64
  }
}
