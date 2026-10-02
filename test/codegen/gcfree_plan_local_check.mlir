// RUN: not %ecoc %s -emit=llvm 2>&1 | %FileCheck %s
// UNSETENV: ECO_CAPHOIST_VALIDATE ECO_GCFREE_VALIDATE
//
// plans/mlir-split-backend-02-gc-leaf-propagation.md fixture (Q7 local check,
// F6): with a forged gc-free plan, a definition stamped gc-leaf that calls a
// declaration that can GC must be rejected before RS4GC. @f has no GC
// strategy, so the post-RS4GC statepoint assert alone would never see it.
//
// CHECK: stamped function 'f' calls 'g', which may GC

module {
  llvm.module_flags [#llvm.mlir.module_flag<warning, "eco-cap-plan", "v1;K=512;m2=1;cw=0;veq=0">, #llvm.mlir.module_flag<warning, "eco-gcfree-plan", "v1;veq=0;cov=1">]
  llvm.func @g()
  llvm.func @f() attributes {passthrough = ["gc-leaf-function", "eco-cap-top"]} {
    llvm.call @g() : () -> ()
    llvm.return
  }
  func.func @main() -> i64 {
    %z = arith.constant 0 : i64
    return %z : i64
  }
}
