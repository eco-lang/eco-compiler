// RUN: not %ecoc %s -emit=mlir 2>&1 | %FileCheck %s
//
// kernel-opt-12: the verifier rejects `eco.cse_safe` on an indirect call.

module {
  func.func @main(%clo: !eco.value, %a: !eco.value) -> i64 {
    %r = "eco.call"(%clo, %a) {remaining_arity = 1 : i64, eco.cse_safe}
       : (!eco.value, !eco.value) -> !eco.value
    %z = arith.constant 0 : i64
    return %z : i64
  }
}

// CHECK: only valid on a direct call
