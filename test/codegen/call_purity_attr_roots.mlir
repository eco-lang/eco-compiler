// RUN: not %ecoc %s -emit=mlir 2>&1 | %FileCheck %s
//
// kernel-opt-12: the verifier rejects `eco.cse_safe` alongside appended GC
// roots — the combination means a purity consumer ran after EcoGCPrepare.

module {
  func.func private @f(%v: !eco.value) -> !eco.value

  func.func @main(%v: !eco.value, %root: !eco.value) -> i64 {
    %r = "eco.call"(%v, %root) {callee = @f, eco.cse_safe, eco.gc_roots_count = 1 : i64}
       : (!eco.value, !eco.value) -> !eco.value
    %z = arith.constant 0 : i64
    return %z : i64
  }
}

// CHECK: must not survive GC root attachment
