// RUN: not %ecoc %s -emit=llvm 2>&1 | %FileCheck %s
//
// SD-20 pin: eco.free is a placeholder for future Perceus-style reference
// counting. In tracing GC mode RCElimination rejects it by name instead of
// lowering it. When reference counting is implemented, replace this CHECK with
// the real lowering.
//
// The op is written in generic form: it has no custom assembly format.

module {
  func.func @main() -> i64 {
    %c42 = arith.constant 42 : i64
    %boxed = eco.box %c42 : i64 -> !eco.value

    "eco.free"(%boxed) : (!eco.value) -> ()
    // CHECK: error: eco.free is not supported in tracing GC mode

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
