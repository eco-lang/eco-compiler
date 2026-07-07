// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test all 7 embedded constants with correct encoding and display.

module {
  func.func @main() -> i64 {
    // Test Nil constant (empty list)
    %nil = eco.constant Empty : !eco.value
    eco.dbg %nil : !eco.value
    // CHECK: <empty>

    // Test Unit constant
    %unit = eco.constant Empty : !eco.value
    eco.dbg %unit : !eco.value
    // CHECK: <empty>

    // Test True constant
    %true = eco.constant True : !eco.value
    eco.dbg %true : !eco.value
    // CHECK: True

    // Test False constant
    %false = eco.constant False : !eco.value
    eco.dbg %false : !eco.value
    // CHECK: False

    // Test Nothing constant (Maybe.Nothing)
    %nothing = eco.constant Empty : !eco.value
    eco.dbg %nothing : !eco.value
    // CHECK: <empty>

    // Test EmptyRec constant (empty record {})
    %empty_rec = eco.constant Empty : !eco.value
    eco.dbg %empty_rec : !eco.value
    // CHECK: <empty>

    // Test EmptyString constant
    %empty_str = eco.constant Empty : !eco.value
    eco.dbg %empty_str : !eco.value
    // CHECK: <empty>

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
