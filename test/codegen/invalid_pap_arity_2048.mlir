// RUN: not %ecoc %s -emit=mlir 2>&1 | %FileCheck %s
//
// Phase 2 (plans/wide-object-tail-kind-words-phase-2.md 2.7): a closure's stage arity is
// at most 2047 (CLOSURE_MAX_ARITY: n_values:11 | max_values:11, HEAP_078).

module {
  func.func @target(%a: i64) -> i64 {
    eco.return %a : i64
  }

  func.func @bad() -> !eco.value {
    %p = "eco.papCreate"() {
      function = @target, arity = 2048 : i64, num_captured = 0 : i64
    } : () -> !eco.value
    return %p : !eco.value
  }
}

// CHECK: arity (2048) exceeds closure arity limit (2047)
