// RUN: not %ecoc %s -emit=mlir 2>&1 | %FileCheck %s
//
// Phase 3 negative: eco.from_heap rejects !eco.closure_env results
// (CGEN_063), mirroring the eco.to_heap rejection rule.

module {
  func.func @bad(%hp: !eco.value) -> !eco.closure_env<i64> {
    %e = eco.from_heap %hp : (!eco.value) -> !eco.closure_env<i64>
    return %e : !eco.closure_env<i64>
  }
}

// CHECK: error
// CHECK: closure_env
