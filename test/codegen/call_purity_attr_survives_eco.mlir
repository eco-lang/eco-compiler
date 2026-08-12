// RUN: %ecoc %s -emit=mlir-eco 2>&1 | %FileCheck %s
//
// kernel-opt-12: the purity channel must survive RCElimination / PAPSimplify /
// CompareCaseRewrite / UndefinedFunction unchanged — it only dies at
// EcoGCPrepare, which is in the LLVM-lowering pipeline, not this one.

module {
  func.func private @sideEffecting(%v: !eco.value) -> !eco.value {
    eco.dbg %v : !eco.value
    eco.return %v : !eco.value
  }

  func.func @main() -> i64 {
    %c = arith.constant 5 : i64
    %v = eco.box %c : i64 -> !eco.value
    %r = "eco.call"(%v) {callee = @sideEffecting, eco.cse_safe} : (!eco.value) -> !eco.value
    eco.dbg %r : !eco.value
    %z = arith.constant 0 : i64
    return %z : i64
  }
}

// CHECK: "eco.call"
// CHECK-SAME: eco.cse_safe
