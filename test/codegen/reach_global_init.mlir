// RUN: %ecoc %s -emit=mlir-llvm --exe-reachability 2>&1 | %FileCheck %s
//
// plans/mlir-split-backend-03-reachability.md fixture (CGEN_081): references
// inside a global's INITIALIZER region are edges. A function reached only from
// a dead global's initializer dies with it; one reached from a live global's
// initializer lives (and both become internal).
//
// CHECK: llvm.mlir.global internal constant @glive(
// CHECK: llvm.func internal @flive(
// CHECK-NOT: @gdead
// CHECK-NOT: @fdead

module {
  llvm.func @fdead() {
    llvm.return
  }
  llvm.func @flive() {
    llvm.return
  }
  llvm.mlir.global external constant @gdead() : !llvm.ptr {
    %f = llvm.mlir.addressof @fdead : !llvm.ptr
    llvm.return %f : !llvm.ptr
  }
  llvm.mlir.global external constant @glive() : !llvm.ptr {
    %f = llvm.mlir.addressof @flive : !llvm.ptr
    llvm.return %f : !llvm.ptr
  }
  llvm.func @main() -> i64 {
    %p = llvm.mlir.addressof @glive : !llvm.ptr
    %v = llvm.load %p : !llvm.ptr -> !llvm.ptr
    llvm.call %v() : !llvm.ptr, () -> ()
    %z = llvm.mlir.constant(0 : i64) : i64
    llvm.return %z : i64
  }
}
