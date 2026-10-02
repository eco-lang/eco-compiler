// RUN: %ecoc %s -emit=mlir-llvm 2>&1 | %FileCheck %s
//
// plans/mlir-split-backend-02-gc-leaf-propagation.md fixture: the marker
// table's FINAL view (EcoMarkerFacts.h). Cursor markers are declared WITHOUT
// gc-leaf yet expand leaf-only (O2), so their callers are stamped; list-tail
// and sat markers expand into calls that can GC, so theirs are not. A libm
// call (the TLI arm) and a recognised intrinsic are leaf.
//
// CHECK: llvm.func internal @cur() {{.*}}"gc-leaf-function"
// CHECK: llvm.func internal @libm(%{{.*}}"gc-leaf-function"
// CHECK: llvm.func internal @intr() {{.*}}"gc-leaf-function"
// CHECK-NOT: @tail() {{.*}}gc-leaf-function
// CHECK-NOT: @sat() {{.*}}gc-leaf-function

module {
  llvm.func @__eco_list_cur_inline(i64) -> i64
  llvm.func @__eco_list_tail_inline(!llvm.ptr<1>) -> !llvm.ptr<1> attributes {passthrough = ["gc-leaf-function"]}
  llvm.func @__eco_sat_begin() attributes {passthrough = ["gc-leaf-function"]}
  llvm.func @sqrt(f64) -> f64
  llvm.func @llvm.donothing()
  llvm.func internal @cur() {
    %c = llvm.mlir.constant(1 : i64) : i64
    %r = llvm.call @__eco_list_cur_inline(%c) : (i64) -> i64
    llvm.return
  }
  llvm.func internal @tail(%p: !llvm.ptr<1>) -> !llvm.ptr<1> {
    %r = llvm.call @__eco_list_tail_inline(%p) : (!llvm.ptr<1>) -> !llvm.ptr<1>
    llvm.return %r : !llvm.ptr<1>
  }
  llvm.func internal @sat() {
    llvm.call @__eco_sat_begin() : () -> ()
    llvm.return
  }
  llvm.func internal @libm(%x: f64) -> f64 {
    %r = llvm.call @sqrt(%x) : (f64) -> f64
    llvm.return %r : f64
  }
  llvm.func internal @intr() {
    llvm.call @llvm.donothing() : () -> ()
    llvm.return
  }
  func.func @main() -> i64 {
    %z = arith.constant 0 : i64
    return %z : i64
  }
}
