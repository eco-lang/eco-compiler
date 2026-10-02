// RUN: %ecoc %s -emit=llvm 2>&1 | %FileCheck %s
// UNSETENV: ECO_CAPHOIST_VALIDATE ECO_GCFREE_VALIDATE
//
// plans/mlir-split-backend-02-gc-leaf-propagation.md fixture (E6 hole found
// while implementing 02): @h is GC-free, so EcoGcFreePropagation stamps it
// gc-leaf BEFORE capacity hoisting runs. A type-mismatched call through
// `addressof @h` has no getCalledFunction(), and callsGCLeafFunction reads
// gc-leaf off the called operand, so it would read as transparent and merge
// the two markers into one 40-byte run. A GC-free function may still consume
// nursery headroom, so the call must stay a run BREAKER (leafForAnalysis).
//
// CHECK-LABEL: define {{.*}}@f(
// CHECK-NOT: @eco_ensure_nursery_slow{{.*}}i64 40

module {
  llvm.module_flags [#llvm.mlir.module_flag<warning, "eco-cap-plan", "v1;K=512;m2=1;cw=0;veq=0">]
  llvm.func @__eco_alloc_inline(i64) -> !llvm.ptr<1> attributes {passthrough = ["gc-leaf-function"]}
  llvm.func internal @h(%x: i64) attributes {passthrough = ["eco-cap-top"]} {
    llvm.return
  }
  llvm.func internal @f() -> !llvm.ptr<1> attributes {passthrough = ["eco-cap-top"]} {
    %c16 = llvm.mlir.constant(16 : i64) : i64
    %c24 = llvm.mlir.constant(24 : i64) : i64
    %hp = llvm.mlir.addressof @h : !llvm.ptr
    %a = llvm.call @__eco_alloc_inline(%c16) : (i64) -> !llvm.ptr<1>
    llvm.call %hp() : !llvm.ptr, () -> ()
    %b = llvm.call @__eco_alloc_inline(%c24) : (i64) -> !llvm.ptr<1>
    llvm.return %b : !llvm.ptr<1>
  }
  func.func @main() -> i64 {
    %z = arith.constant 0 : i64
    return %z : i64
  }
}
