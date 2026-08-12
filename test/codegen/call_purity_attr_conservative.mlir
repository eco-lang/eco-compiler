// RUN: %ecoc %s -emit=mlir-llvm 2>&1 | %FileCheck %s
//
// kernel-opt-12 Trap D: declaring MemoryEffectOpInterface on Eco_CallOp
// flips the default. A call WITHOUT `eco.cse_safe` reports conservative
// read+write and must NEVER be erased, even with its result unused. This
// fixture was green BEFORE the interface landed, so a red run after it is
// unambiguous: the conservative branch is wrong.

module {
  func.func private @sideEffecting(%v: !eco.value) -> !eco.value {
    eco.dbg %v : !eco.value
    eco.return %v : !eco.value
  }

  func.func @main() -> i64 {
    %c = arith.constant 7 : i64
    %v = eco.box %c : i64 -> !eco.value
    %unused = "eco.call"(%v) {callee = @sideEffecting} : (!eco.value) -> !eco.value
    %z = arith.constant 0 : i64
    return %z : i64
  }
}

// CHECK: llvm.call @sideEffecting
