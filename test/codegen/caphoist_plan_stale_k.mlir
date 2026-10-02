// RUN: not %ecoc %s -emit=llvm 2>&1 | %FileCheck %s
// UNSETENV: ECO_CAPHOIST_VALIDATE
//
// plans/mlir-split-backend-01-cap-hoist-plan.md fixture (d): a plan computed
// with a different budget cap K (e.g. a stale re-lowered dump) must be
// refused, not silently applied with the backend's K.
//
// CHECK: plan stamp mismatch

module {
  llvm.module_flags [#llvm.mlir.module_flag<warning, "eco-cap-plan", "v1;K=1024;m2=1;cw=0;veq=0">]
  llvm.func @__eco_alloc_inline(i64) -> !llvm.ptr<1> attributes {passthrough = ["gc-leaf-function"]}
  llvm.func internal @f() -> !llvm.ptr<1> attributes {passthrough = ["eco-cap-top"]} {
    %c16 = llvm.mlir.constant(16 : i64) : i64
    %a = llvm.call @__eco_alloc_inline(%c16) : (i64) -> !llvm.ptr<1>
    llvm.return %a : !llvm.ptr<1>
  }
  func.func @main() -> i64 {
    %z = arith.constant 0 : i64
    return %z : i64
  }
}
