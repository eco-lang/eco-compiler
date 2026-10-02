// RUN: %ecoc %s -emit=mlir-llvm --exe-reachability 2>&1 | %FileCheck %s
//
// plans/mlir-split-backend-03-reachability.md fixture (§3, M2): an
// `llvm.mlir.addressof` with no uses becomes no LLVM use after translation, so
// it must not keep its target alive.
//
// CHECK-NOT: @f(
// CHECK: llvm.func @main(

module {
  llvm.func @f() {
    llvm.return
  }
  llvm.func @main() -> i64 {
    %unused = llvm.mlir.addressof @f : !llvm.ptr
    %z = llvm.mlir.constant(0 : i64) : i64
    llvm.return %z : i64
  }
}
