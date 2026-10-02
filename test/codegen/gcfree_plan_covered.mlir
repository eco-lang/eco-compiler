// RUN: %ecoc %s -emit=mlir-llvm 2>&1 | %FileCheck %s
// UNSETENV: ECO_CAPHOIST_VALIDATE ECO_GCFREE_VALIDATE
//
// plans/mlir-split-backend-02-gc-leaf-propagation.md fixture (O3): the one
// fact 02 needs from capacity hoisting is eco-cap-covered. A covered
// function's alloc markers become unchecked bumps (leaf); a non-covered
// function's markers keep a slow call or an ensure; a non-covered caller of
// a covered callee holds an ensure. The cap plan here is forged.
//
// CHECK: llvm.func internal @c() {{.*}}"gc-leaf-function"
// CHECK-NOT: @n() {{.*}}gc-leaf-function
// CHECK-NOT: @k() {{.*}}gc-leaf-function
// CHECK: "eco-gcfree-plan", "v1;veq=0;cov=1"

module {
  llvm.module_flags [#llvm.mlir.module_flag<warning, "eco-cap-plan", "v1;K=512;m2=1;cw=0;veq=0">]
  llvm.func @__eco_alloc_inline(i64) -> !llvm.ptr<1> attributes {passthrough = ["gc-leaf-function"]}
  llvm.func internal @c() -> !llvm.ptr<1> attributes {passthrough = [["eco-cap-budget", "16"], "eco-cap-covered"]} {
    %c16 = llvm.mlir.constant(16 : i64) : i64
    %a = llvm.call @__eco_alloc_inline(%c16) : (i64) -> !llvm.ptr<1>
    llvm.return %a : !llvm.ptr<1>
  }
  llvm.func internal @n() -> !llvm.ptr<1> attributes {passthrough = ["eco-cap-top"]} {
    %c16 = llvm.mlir.constant(16 : i64) : i64
    %a = llvm.call @__eco_alloc_inline(%c16) : (i64) -> !llvm.ptr<1>
    llvm.return %a : !llvm.ptr<1>
  }
  llvm.func internal @k() -> !llvm.ptr<1> attributes {passthrough = ["eco-cap-top"]} {
    %r = llvm.call @c() : () -> !llvm.ptr<1>
    llvm.return %r : !llvm.ptr<1>
  }
  func.func @main() -> i64 {
    %z = arith.constant 0 : i64
    return %z : i64
  }
}
