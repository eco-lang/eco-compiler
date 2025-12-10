// RUN: %ecoc %s -emit=mlir-llvm 2>&1 | %FileCheck %s
//
// Test that eco.constant lowers to correct i64 encoded values.
// This verifies the lowering pass output, not runtime behavior.

module {
  // Use a function that returns the constant to prevent optimization
  func.func @get_nil() -> !eco.value {
    // Nil constant should lower to (5 << 40) = 5497558138880
    %nil = eco.constant Nil : !eco.value
    // CHECK: 5497558138880
    return %nil : !eco.value
  }

  func.func @get_true() -> !eco.value {
    // True constant should lower to (3 << 40) = 3298534883328
    %true = eco.constant True : !eco.value
    // CHECK: 3298534883328
    return %true : !eco.value
  }

  func.func @get_unit() -> !eco.value {
    // Unit constant should lower to (1 << 40) = 1099511627776
    %unit = eco.constant Unit : !eco.value
    // CHECK: 1099511627776
    return %unit : !eco.value
  }

  func.func @main() -> i64 {
    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
