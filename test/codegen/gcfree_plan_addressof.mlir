// RUN: %ecoc %s -emit=mlir-llvm 2>&1 | %FileCheck %s
//
// plans/mlir-split-backend-02-gc-leaf-propagation.md fixture (O7/E6): LLVM's
// callsGCLeafFunction reads gc-leaf off the called OPERAND with no type check,
// so a type-mismatched call through `addressof` to a gc-leaf DECLARATION is
// leaf; the same call to a non-leaf declaration is poison.
//
// CHECK: llvm.func internal @viaLeaf() {{.*}}"gc-leaf-function"
// CHECK-NOT: @viaGc() {{.*}}gc-leaf-function

module {
  llvm.func @leafdecl(i64) attributes {passthrough = ["gc-leaf-function"]}
  llvm.func @gcdecl(i64)
  llvm.func internal @viaLeaf() {
    %f = llvm.mlir.addressof @leafdecl : !llvm.ptr
    llvm.call %f() : !llvm.ptr, () -> ()
    llvm.return
  }
  llvm.func internal @viaGc() {
    %f = llvm.mlir.addressof @gcdecl : !llvm.ptr
    llvm.call %f() : !llvm.ptr, () -> ()
    llvm.return
  }
  func.func @main() -> i64 {
    %z = arith.constant 0 : i64
    return %z : i64
  }
}
