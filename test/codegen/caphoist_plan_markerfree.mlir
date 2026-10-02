// RUN: %ecoc %s -emit=llvm 2>&1 | %FileCheck %s
// UNSETENV: ECO_CAPHOIST_VALIDATE
//
// plans/mlir-split-backend-01-cap-hoist-plan.md fixture (e): a function with
// NO allocation markers of its own that calls a covered callee must still
// reserve the callee's budget (the plan stamp lives on the module, not on the
// marker declaration, so a marker-free module/partition is still plan-given).
//
// CHECK-LABEL: define {{.*}}@f(
// CHECK: @eco_ensure_nursery_slow{{.*}}i64 48

module {
  llvm.module_flags [#llvm.mlir.module_flag<warning, "eco-cap-plan", "v1;K=512;m2=1;cw=0;veq=0">]
  llvm.func @g() -> !llvm.ptr<1> attributes {passthrough = ["eco-cap-covered", ["eco-cap-budget", "48"]]}
  llvm.func internal @f() -> !llvm.ptr<1> attributes {passthrough = ["eco-cap-top"]} {
    %r = llvm.call @g() : () -> !llvm.ptr<1>
    llvm.return %r : !llvm.ptr<1>
  }
  func.func @main() -> i64 {
    %z = arith.constant 0 : i64
    return %z : i64
  }
}
