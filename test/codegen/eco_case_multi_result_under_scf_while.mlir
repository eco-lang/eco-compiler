// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test multi-result eco.case with eco.yield terminators inside scf.while after-region.
// This validates the yield-based eco.case encoding required for TailRec compilation.
//
// Pattern:
//   scf.while with multi-value loop state (params..., done, result)
//   In after-region: eco.case that yields (next_params..., done, result)
//   Alternatives terminate with eco.yield (multi-operand)
//   After-region terminates with scf.yield

module {
  // Test function: countdown that uses eco.case to decide continue vs done
  // Returns the final value (should be 0)
  func.func @countdown_with_case(%start: i64) -> i64 {
    %c0 = arith.constant 0 : i64
    %c1 = arith.constant 1 : i64
    %false = arith.constant false
    %true = arith.constant true

    // Loop state: (counter: i64, done: i1, result: i64)
    // scf.while carries all three values
    %final_counter, %final_done, %final_result = scf.while (%counter = %start, %done = %false, %result = %c0)
        : (i64, i1, i64) -> (i64, i1, i64) {
      // Before region: check if done
      %continue = arith.xori %done, %true : i1
      scf.condition(%continue) %counter, %done, %result : i64, i1, i64
    } do {
    ^bb0(%c: i64, %d: i1, %r: i64):
      // After region: use eco.case to decide next state
      // eco.case returns (next_counter, next_done, next_result)
      %is_zero = arith.cmpi eq, %c, %c0 : i64
      %tag = arith.extui %is_zero : i1 to i64
      %boxed_tag = eco.box %tag : i64 -> !eco.value

      // Multi-result eco.case with yield-based encoding
      // Format: eco.case %scrutinee : type [tags] -> (result_types) {attr-dict} { alt1 }, { alt2 }
      %next_c, %next_d, %next_r = eco.case %boxed_tag : !eco.value [0, 1] -> (i64, i1, i64) {case_kind = "ctor"} {
        // Tag 0: counter > 0, continue looping
        %dec = arith.subi %c, %c1 : i64
        eco.yield %dec, %false, %r : i64, i1, i64
      }, {
        // Tag 1: counter == 0, we're done
        eco.yield %c, %true, %c : i64, i1, i64
      }

      scf.yield %next_c, %next_d, %next_r : i64, i1, i64
    }

    return %final_result : i64
  }

  func.func @main() -> i64 {
    %c0 = arith.constant 0 : i64
    %c5 = arith.constant 5 : i64

    // Test countdown from 5 - should return 0
    %result = func.call @countdown_with_case(%c5) : (i64) -> i64
    eco.dbg %result : i64
    // CHECK: 0

    return %c0 : i64
  }
}
