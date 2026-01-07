// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test nested case expressions (case inside case branch).
// This tests region inlining with nested regions.

module {
  func.func @main() -> i64 {
    %c10 = arith.constant 10 : i64
    %c20 = arith.constant 20 : i64
    %c30 = arith.constant 30 : i64

    %b10 = eco.box %c10 : i64 -> !eco.value
    %b20 = eco.box %c20 : i64 -> !eco.value
    %b30 = eco.box %c30 : i64 -> !eco.value

    // Create Maybe-like: Nothing (tag 0), Just (tag 1)
    // Create Result-like: Err (tag 0), Ok (tag 1)
    %nothing = eco.construct.custom() {tag = 0 : i64, size = 0 : i64} : () -> !eco.value
    %just10 = eco.construct.custom(%b10) {tag = 1 : i64, size = 1 : i64} : (!eco.value) -> !eco.value
    %err20 = eco.construct.custom(%b20) {tag = 0 : i64, size = 1 : i64} : (!eco.value) -> !eco.value
    %ok30 = eco.construct.custom(%b30) {tag = 1 : i64, size = 1 : i64} : (!eco.value) -> !eco.value

    // Outer case on Maybe, inner case on Result
    // Pattern: case maybe of Nothing -> 0; Just r -> case r of Err _ -> 1; Ok v -> v
    eco.case %just10 [0, 1] {
      // Nothing branch
      %r0 = arith.constant 0 : i64
      eco.dbg %r0 : i64
      eco.return
    }, {
      // Just branch - extract payload and case on it
      %payload = eco.project.custom %just10[0] : !eco.value -> !eco.value

      // But here payload is just b10, not a Result
      // Let's test with a proper nested structure
      %unboxed = eco.unbox %payload : !eco.value -> i64
      eco.dbg %unboxed : i64
      eco.return
    }
    // CHECK: 10

    // More realistic: Nested case with actual Result inside Maybe
    // Create Just(Ok(30))
    %just_ok = eco.construct.custom(%ok30) {tag = 1 : i64, size = 1 : i64} : (!eco.value) -> !eco.value

    eco.case %just_ok [0, 1] {
      // Nothing
      %r0 = arith.constant 0 : i64
      eco.dbg %r0 : i64
      eco.return
    }, {
      // Just - extract Result and case on it
      %inner_result = eco.project.custom %just_ok[0] : !eco.value -> !eco.value

      eco.case %inner_result [0, 1] {
        // Err
        %err_val = arith.constant 999 : i64
        eco.dbg %err_val : i64
        eco.return
      }, {
        // Ok - extract value
        %ok_payload = eco.project.custom %inner_result[0] : !eco.value -> !eco.value
        %final = eco.unbox %ok_payload : !eco.value -> i64
        eco.dbg %final : i64
        eco.return
      }
      eco.return
    }
    // CHECK: 30

    // Test Just(Err(20))
    %just_err = eco.construct.custom(%err20) {tag = 1 : i64, size = 1 : i64} : (!eco.value) -> !eco.value

    eco.case %just_err [0, 1] {
      %r0 = arith.constant 0 : i64
      eco.dbg %r0 : i64
      eco.return
    }, {
      %inner = eco.project.custom %just_err[0] : !eco.value -> !eco.value
      eco.case %inner [0, 1] {
        // Err branch
        %err_payload = eco.project.custom %inner[0] : !eco.value -> !eco.value
        %err_unboxed = eco.unbox %err_payload : !eco.value -> i64
        %negated = eco.int.negate %err_unboxed : i64
        eco.dbg %negated : i64
        eco.return
      }, {
        %ok_val = arith.constant 999 : i64
        eco.dbg %ok_val : i64
        eco.return
      }
      eco.return
    }
    // CHECK: -20

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
