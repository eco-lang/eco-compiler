// RUN: not %ecoc %s -emit=mlir 2>&1 | %FileCheck %s
//
// SD-6: a direct eco.call is not checked against the callee's func.func
// signature (CallOp::verify returns success for every direct call; see
// EcoOps.cpp). Here @target takes two parameters and returns i64, but the
// call passes one argument and claims an !eco.value result. The eco verifier
// must report it rather than leaving it to LLVM.

module {
  func.func @target(%a: i64, %b: i64) -> i64 {
    eco.return %a : i64
  }

  func.func @main() -> !eco.value {
    %i = arith.constant 7 : i64
    %r = "eco.call"(%i) {callee = @target} : (i64) -> !eco.value
    eco.return %r : !eco.value
  }
}

// CHECK: error: 'eco.call' op {{.*}}target
