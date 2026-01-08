// RUN: %ecoc %s -emit=mlir 2>&1 | %FileCheck %s
//
// Test that eco.construct verification catches mismatched field counts.
// This is a NEGATIVE test - we expect an error.

module {
  func.func @main() -> i64 {
    %nil = eco.constant Nil : !eco.value
    %i1 = arith.constant 1 : i64
    %b1 = eco.box %i1 : i64 -> !eco.value

    // ERROR: size=3 but only 2 fields provided
    // CHECK: 'eco.construct.custom' op number of fields (2) must match size attribute (3)
    %bad = eco.construct.custom(%b1, %nil) {tag = 0 : i64, size = 3 : i64} : (!eco.value, !eco.value) -> !eco.value

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
