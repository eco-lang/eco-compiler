// RUN: not %ecoc %s -emit=llvm 2>&1 | %FileCheck %s
//
// SD-20 pin: eco.reset and eco.reset_ref are placeholders for future
// Perceus-style reuse. In tracing GC mode RCElimination rejects each one by name
// instead of lowering it. When reuse is implemented, replace these CHECKs with
// the real lowering.
//
// The ops are written in generic form: they have no custom assembly format.
// Both return the reset value.

module {
  func.func @main() -> i64 {
    %c42 = arith.constant 42 : i64
    %boxed = eco.box %c42 : i64 -> !eco.value

    %r = "eco.reset"(%boxed) : (!eco.value) -> !eco.value
    // CHECK: error: eco.reset is not supported in tracing GC mode
    %rr = "eco.reset_ref"(%boxed) : (!eco.value) -> !eco.value
    // CHECK: error: eco.reset_ref is not supported in tracing GC mode

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
