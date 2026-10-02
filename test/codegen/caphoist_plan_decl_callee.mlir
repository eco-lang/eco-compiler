// RUN: %ecoc %s -emit=llvm 2>&1 | %FileCheck %s
// UNSETENV: ECO_CAPHOIST_VALIDATE
//
// plans/mlir-split-backend-01-cap-hoist-plan.md fixture (a): plan-given
// capacity hoisting reads a covered callee's budget from its DECLARATION's
// eco-cap facts (after the split a covered callee in another partition is a
// declaration). @f's own two markers (16 + 24) and the call to the covered
// @g (48) form one run, so one ensure reserves 16 + 24 + 48 = 88 bytes.
//
// CHECK-LABEL: define {{.*}}@f(
// CHECK: @eco_ensure_nursery_slow{{.*}}i64 88
// CHECK-NOT: eco-cap-

module {
  llvm.module_flags [#llvm.mlir.module_flag<warning, "eco-cap-plan", "v1;K=512;m2=1;cw=0;veq=0">]
  llvm.func @__eco_alloc_inline(i64) -> !llvm.ptr<1> attributes {passthrough = ["gc-leaf-function"]}
  llvm.func @g() -> !llvm.ptr<1> attributes {passthrough = ["eco-cap-covered", ["eco-cap-budget", "48"]]}
  llvm.func internal @f() -> !llvm.ptr<1> attributes {passthrough = ["eco-cap-top"]} {
    %c16 = llvm.mlir.constant(16 : i64) : i64
    %c24 = llvm.mlir.constant(24 : i64) : i64
    %a = llvm.call @__eco_alloc_inline(%c16) : (i64) -> !llvm.ptr<1>
    %b = llvm.call @__eco_alloc_inline(%c24) : (i64) -> !llvm.ptr<1>
    %r = llvm.call @g() : () -> !llvm.ptr<1>
    llvm.return %r : !llvm.ptr<1>
  }
  func.func @main() -> i64 {
    %z = arith.constant 0 : i64
    return %z : i64
  }
}
