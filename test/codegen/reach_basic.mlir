// RUN: %ecoc %s -emit=mlir-llvm --exe-reachability 2>&1 | %FileCheck %s
//
// plans/mlir-split-backend-03-reachability.md fixture (CGEN_081): closed-world
// reachability in MLIR. `main` stays external; what it reaches becomes
// internal; everything else — a dead function, its callee, a global and a
// declaration only the dead code uses — is erased, as LLVM's internalize +
// GlobalDCE did on the translated module.
//
// CHECK: llvm.func internal @live(
// CHECK-NOT: internal @main(
// CHECK: llvm.func @main(
// CHECK-NOT: @dead(
// CHECK-NOT: @deadcallee(
// CHECK-NOT: @gdead
// CHECK-NOT: @declOnlyDead
// CHECK: "eco-reach", "v1"

module {
  llvm.func @declOnlyDead()
  llvm.mlir.global external @gdead(0 : i64) : i64
  llvm.func @live() {
    llvm.return
  }
  llvm.func @deadcallee() {
    llvm.call @declOnlyDead() : () -> ()
    llvm.return
  }
  llvm.func @dead() -> i64 {
    llvm.call @deadcallee() : () -> ()
    %p = llvm.mlir.addressof @gdead : !llvm.ptr
    %v = llvm.load %p : !llvm.ptr -> i64
    llvm.return %v : i64
  }
  llvm.func @main() -> i64 {
    llvm.call @live() : () -> ()
    %z = llvm.mlir.constant(0 : i64) : i64
    llvm.return %z : i64
  }
}
