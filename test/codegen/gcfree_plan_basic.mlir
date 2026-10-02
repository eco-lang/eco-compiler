// RUN: %ecoc %s -emit=mlir-llvm 2>&1 | %FileCheck %s
//
// plans/mlir-split-backend-02-gc-leaf-propagation.md fixture: the MLIR
// gc-free fixpoint (EcoGcFreePropagation, CGEN_072). Leaf bodies, calls to
// gc-leaf declarations and poison-free cycles are stamped; a call to a
// non-leaf declaration poisons its function and every caller.
//
// CHECK: llvm.func internal @leaf() {{.*}}"gc-leaf-function"
// CHECK: llvm.func internal @mid() {{.*}}"gc-leaf-function"
// CHECK: llvm.func internal @a() {{.*}}"gc-leaf-function"
// CHECK: llvm.func internal @b() {{.*}}"gc-leaf-function"
// CHECK-NOT: @bad() {{.*}}gc-leaf-function
// CHECK-NOT: @up() {{.*}}gc-leaf-function
// CHECK: "eco-gcfree-plan", "v1;veq=0;cov=1"

module {
  llvm.func @leafdecl() attributes {passthrough = ["gc-leaf-function"]}
  llvm.func @gcdecl()
  llvm.func internal @leaf() {
    llvm.return
  }
  llvm.func internal @mid() {
    llvm.call @leaf() : () -> ()
    llvm.call @leafdecl() : () -> ()
    llvm.return
  }
  llvm.func internal @bad() {
    llvm.call @gcdecl() : () -> ()
    llvm.return
  }
  llvm.func internal @up() {
    llvm.call @mid() : () -> ()
    llvm.call @bad() : () -> ()
    llvm.return
  }
  llvm.func internal @a() {
    llvm.call @b() : () -> ()
    llvm.return
  }
  llvm.func internal @b() {
    llvm.call @a() : () -> ()
    llvm.return
  }
  func.func @main() -> i64 {
    %z = arith.constant 0 : i64
    return %z : i64
  }
}
