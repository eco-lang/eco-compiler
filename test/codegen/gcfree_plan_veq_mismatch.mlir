// RUN: not %ecoc %s -emit=llvm 2>&1 | %FileCheck %s
// UNSETENV: ECO_CAPHOIST_VALIDATE ECO_GCFREE_VALIDATE
//
// plans/mlir-split-backend-02-gc-leaf-propagation.md fixture (F10): the two
// plan stamps must agree on the value-eq row of the marker table, or the
// backend's hoisting and gc-free views of `__eco_value_eq` differ.
//
// CHECK: disagree on value-eq leafness

module {
  llvm.module_flags [#llvm.mlir.module_flag<warning, "eco-cap-plan", "v1;K=512;m2=1;cw=0;veq=0">, #llvm.mlir.module_flag<warning, "eco-gcfree-plan", "v1;veq=1;cov=1">]
  func.func @main() -> i64 {
    %z = arith.constant 0 : i64
    return %z : i64
  }
}
