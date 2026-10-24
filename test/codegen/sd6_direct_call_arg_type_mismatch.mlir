// RUN: not %ecoc %s -emit=mlir 2>&1 | %FileCheck %s
//
// SD-6: a direct eco.call (callee attribute present) is not checked against
// the callee's func.func signature. CallOp::verify returns success for every
// direct call ("No signature validation against the callee", EcoOps.cpp) and
// CallOp::verifySymbolUses only checks that the symbol exists, so a mismatch
// shows up only later as LLVM's "Calling a function with a bad signature!"
// (or not at all). Here @target takes (i64, !eco.value) but the call passes
// (!eco.value, i64). The eco verifier must report it.

module {
  func.func @target(%a: i64, %b: !eco.value) -> !eco.value {
    eco.return %b : !eco.value
  }

  func.func @main() -> !eco.value {
    %v = eco.constant Empty : !eco.value
    %i = arith.constant 7 : i64
    %r = "eco.call"(%v, %i) {callee = @target} : (!eco.value, i64) -> !eco.value
    eco.return %r : !eco.value
  }
}

// CHECK: error: 'eco.call' op {{.*}}target
