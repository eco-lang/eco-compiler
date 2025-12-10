// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test eco.constant for all embedded constant kinds.

module {
  func.func @main() -> i64 {
    // Test Nil constant (empty list)
    %nil = eco.constant Nil : !eco.value
    eco.dbg %nil : !eco.value
    // CHECK: []

    // Test Unit constant
    %unit = eco.constant Unit : !eco.value
    eco.dbg %unit : !eco.value
    // CHECK: ()

    // Test True constant
    %true = eco.constant True : !eco.value
    eco.dbg %true : !eco.value
    // CHECK: True

    // Test False constant
    %false = eco.constant False : !eco.value
    eco.dbg %false : !eco.value
    // CHECK: False

    // Test Nothing constant (Maybe.Nothing)
    %nothing = eco.constant Nothing : !eco.value
    eco.dbg %nothing : !eco.value
    // CHECK: Nothing

    // Test EmptyString constant
    %empty_str = eco.constant EmptyString : !eco.value
    eco.dbg %empty_str : !eco.value
    // CHECK: ""

    // Test EmptyRec constant
    %empty_rec = eco.constant EmptyRec : !eco.value
    eco.dbg %empty_rec : !eco.value
    // CHECK: {}

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
