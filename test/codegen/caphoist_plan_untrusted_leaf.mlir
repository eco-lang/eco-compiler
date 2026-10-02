// RUN: not %ecoc %s -emit=llvm 2>&1 | %FileCheck %s
// UNSETENV: ECO_CAPHOIST_VALIDATE
//
// plans/mlir-split-backend-01-cap-hoist-plan.md fixture (h), the R1 gap: a
// gc-leaf declaration WITHOUT eco-cap facts must carry a runtime/kernel name.
// A generated callee whose copied facts were lost (but kept gc-leaf) would
// otherwise be classified as a transparent leaf and its budget dropped.
//
// CHECK: untrusted gc-leaf declaration 'weird' without eco-cap facts

module {
  llvm.module_flags [#llvm.mlir.module_flag<warning, "eco-cap-plan", "v1;K=512;m2=1;cw=0;veq=0">]
  llvm.func @weird() -> !llvm.ptr<1> attributes {passthrough = ["gc-leaf-function"]}
  llvm.func internal @f() -> !llvm.ptr<1> attributes {passthrough = ["eco-cap-top"]} {
    %r = llvm.call @weird() : () -> !llvm.ptr<1>
    llvm.return %r : !llvm.ptr<1>
  }
  func.func @main() -> i64 {
    %z = arith.constant 0 : i64
    return %z : i64
  }
}
