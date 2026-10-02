// RUN: not %ecoc %s -emit=llvm 2>&1 | %FileCheck %s
// UNSETENV: ECO_CAPHOIST_VALIDATE
//
// plans/mlir-split-backend-01-cap-hoist-plan.md fixture (f): a forged plan
// covering @f, which calls the covered @g inside a loop. Each iteration would
// bump @g's 48 bytes under @f's single reservation; the local verification
// must refuse it (Phase B makes such a caller ⊤).
//
// CHECK: plan verification failed for covered function 'f': calls a budgeted callee in a loop

module {
  llvm.module_flags [#llvm.mlir.module_flag<warning, "eco-cap-plan", "v1;K=512;m2=1;cw=0;veq=0">]
  llvm.func @g() -> !llvm.ptr<1> attributes {passthrough = ["eco-cap-covered", ["eco-cap-budget", "48"]]}
  llvm.func internal @f(%n: i64) -> !llvm.ptr<1> attributes {passthrough = ["eco-cap-covered", ["eco-cap-budget", "48"]]} {
    %c0 = llvm.mlir.constant(0 : i64) : i64
    %c1 = llvm.mlir.constant(1 : i64) : i64
    llvm.br ^loop(%c0 : i64)
  ^loop(%i: i64):
    %r = llvm.call @g() : () -> !llvm.ptr<1>
    %j = llvm.add %i, %c1 : i64
    %done = llvm.icmp "sge" %j, %n : i64
    llvm.cond_br %done, ^exit, ^loop(%j : i64)
  ^exit:
    %z = llvm.mlir.zero : !llvm.ptr<1>
    llvm.return %z : !llvm.ptr<1>
  }
  func.func @main() -> i64 {
    %z = arith.constant 0 : i64
    return %z : i64
  }
}
