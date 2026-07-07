// RUN: %ecoc %s -emit=mlir-llvm 2>&1 | %FileCheck %s
//
// Test that eco.constant lowers to correct i64 encoded values.
// This verifies the lowering pass output, not runtime behavior.

module {
  // Use a function that returns the constant to prevent optimization
  func.func @get_nil() -> !eco.value {
    // Empty constant should lower to word 6
    %nil = eco.constant Empty : !eco.value
    // CHECK: llvm.mlir.constant(6 : i64)
    return %nil : !eco.value
  }

  func.func @get_true() -> !eco.value {
    // True constant should lower to word 5
    %true = eco.constant True : !eco.value
    // CHECK: llvm.mlir.constant(5 : i64)
    return %true : !eco.value
  }

  func.func @get_unit() -> !eco.value {
    // Empty constant should lower to word 6
    %unit = eco.constant Empty : !eco.value
    // CHECK: llvm.mlir.constant(6 : i64)
    return %unit : !eco.value
  }

  func.func @main() -> i64 {
    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
