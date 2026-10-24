// RUN: not %ecoc %s -emit=llvm 2>&1 | %FileCheck %s
//
// SD-20 pin: eco.incref, eco.decref and eco.decref_shallow are placeholders for
// future Perceus-style reference counting. In tracing GC mode RCElimination
// rejects each one by name instead of lowering it. When reference counting is
// implemented, replace these CHECKs with the real lowering.
//
// The ops are written in generic form: they have no custom assembly format.

module {
  func.func @main() -> i64 {
    %c42 = arith.constant 42 : i64
    %boxed = eco.box %c42 : i64 -> !eco.value

    "eco.incref"(%boxed) {amount = 1 : i64} : (!eco.value) -> ()
    // CHECK: error: eco.incref is not supported in tracing GC mode
    "eco.decref"(%boxed) : (!eco.value) -> ()
    // CHECK: error: eco.decref is not supported in tracing GC mode
    "eco.decref_shallow"(%boxed) : (!eco.value) -> ()
    // CHECK: error: eco.decref_shallow is not supported in tracing GC mode

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
