// RUN: %ecoc %s -emit=mlir-llvm --exe-reachability 2>&1 | %FileCheck %s
//
// plans/mlir-split-backend-03-reachability.md fixture (§10 #12): with none of
// the roots present (library-shaped input) the pass changes nothing and
// records no stamp, so the backend behaves exactly as before.
//
// CHECK: llvm.func @lib(
// CHECK: llvm.func @helper(
// CHECK-NOT: eco-reach

module {
  llvm.func @helper() {
    llvm.return
  }
  llvm.func @lib() {
    llvm.call @helper() : () -> ()
    llvm.return
  }
}
