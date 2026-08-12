// RUN: %ecoc %s -emit=mlir-llvm 2>&1 | %FileCheck %s
//
// kernel-opt-12: EcoGCPrepare strips `eco.cse_safe` before appending GC roots.
// If that strip is ever removed, CallOp::verify's rootCount arm fails this
// module immediately after EcoGCPrepare (the PassManager verifies after every
// pass) and this CHECK never matches. Do NOT "improve" this into a CHECK-NOT
// on eco.cse_safe: the attr is absent from the LLVM-dialect dump for an
// unrelated reason (op conversion drops discardable Eco attrs), so a
// CHECK-NOT would pass even with the strip deleted.

module {
  func.func private @sideEffecting(%v: !eco.value) -> !eco.value {
    eco.dbg %v : !eco.value
    eco.return %v : !eco.value
  }

  func.func @main() -> i64 {
    %c = arith.constant 9 : i64
    %v = eco.box %c : i64 -> !eco.value
    %r = "eco.call"(%v) {callee = @sideEffecting, eco.cse_safe} : (!eco.value) -> !eco.value
    eco.dbg %r : !eco.value
    %z = arith.constant 0 : i64
    return %z : i64
  }
}

// CHECK: llvm.call @sideEffecting
