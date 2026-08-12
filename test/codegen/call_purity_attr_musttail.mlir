// RUN: not %ecoc %s -emit=mlir 2>&1 | %FileCheck %s
//
// kernel-opt-12: the verifier rejects `eco.cse_safe` on a musttail call.

module {
  func.func private @f(%v: !eco.value) -> !eco.value

  func.func @main(%v: !eco.value) -> !eco.value {
    %r = "eco.call"(%v) {callee = @f, musttail = true, eco.cse_safe}
       : (!eco.value) -> !eco.value
    return %r : !eco.value
  }
}

// CHECK: must not be set on a musttail call
