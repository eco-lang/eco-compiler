// RUN: not %ecoc %s -emit=mlir-llvm 2>&1 | %FileCheck %s
//
// plans/mlir-split-backend-02-gc-leaf-propagation.md fixture (table drift): a
// call to an `__eco_` marker with no row in EcoMarkerFacts.h must stop the
// build, never fall back to its declaration's attributes.
//
// CHECK: call to marker '__eco_bogus_inline' without a table row

module {
  llvm.func @__eco_bogus_inline() attributes {passthrough = ["gc-leaf-function"]}
  llvm.func internal @f() {
    llvm.call @__eco_bogus_inline() : () -> ()
    llvm.return
  }
  func.func @main() -> i64 {
    %z = arith.constant 0 : i64
    return %z : i64
  }
}
