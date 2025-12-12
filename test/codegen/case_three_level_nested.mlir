// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test three levels of nested case operations.
// Pattern: case x of A -> case y of B -> case z of C -> value

module {
  func.func @main() -> i64 {
    %c42 = arith.constant 42 : i64
    %c100 = arith.constant 100 : i64
    %c200 = arith.constant 200 : i64

    %b42 = eco.box %c42 : i64 -> !eco.value
    %b100 = eco.box %c100 : i64 -> !eco.value
    %b200 = eco.box %c200 : i64 -> !eco.value

    // Build: Just(Ok(Some(42)))
    // Level 3: Some(42) - tag 1, with value
    %some42 = eco.construct(%b42) {tag = 1 : i64, size = 1 : i64} : (!eco.value) -> !eco.value

    // Level 2: Ok(Some(42)) - tag 1
    %ok_some = eco.construct(%some42) {tag = 1 : i64, size = 1 : i64} : (!eco.value) -> !eco.value

    // Level 1: Just(Ok(Some(42))) - tag 1
    %just_ok_some = eco.construct(%ok_some) {tag = 1 : i64, size = 1 : i64} : (!eco.value) -> !eco.value

    // Three level nested case
    eco.case %just_ok_some [0, 1] {
      // Nothing case
      %r0 = arith.constant -1 : i64
      eco.dbg %r0 : i64
      eco.return
    }, {
      // Just case - level 1 matched
      %level1 = arith.constant 1 : i64
      eco.dbg %level1 : i64

      %inner1 = eco.project %just_ok_some[0] : !eco.value -> !eco.value

      eco.case %inner1 [0, 1] {
        // Err case
        %r1 = arith.constant -2 : i64
        eco.dbg %r1 : i64
        eco.return
      }, {
        // Ok case - level 2 matched
        %level2 = arith.constant 2 : i64
        eco.dbg %level2 : i64

        %inner2 = eco.project %inner1[0] : !eco.value -> !eco.value

        eco.case %inner2 [0, 1] {
          // None case
          %r2 = arith.constant -3 : i64
          eco.dbg %r2 : i64
          eco.return
        }, {
          // Some case - level 3 matched, extract final value
          %level3 = arith.constant 3 : i64
          eco.dbg %level3 : i64

          %final = eco.project %inner2[0] : !eco.value -> !eco.value
          eco.dbg %final : !eco.value
          eco.return
        }
        eco.return
      }
      eco.return
    }
    // Should print: 1, 2, 3, 42
    // CHECK: [eco.dbg] 1
    // CHECK: [eco.dbg] 2
    // CHECK: [eco.dbg] 3
    // CHECK: [eco.dbg] 42

    // Test a different path: Just(Err(value))
    %err_val = eco.construct(%b100) {tag = 0 : i64, size = 1 : i64} : (!eco.value) -> !eco.value
    %just_err = eco.construct(%err_val) {tag = 1 : i64, size = 1 : i64} : (!eco.value) -> !eco.value

    eco.case %just_err [0, 1] {
      %r0 = arith.constant -10 : i64
      eco.dbg %r0 : i64
      eco.return
    }, {
      %l1 = arith.constant 10 : i64
      eco.dbg %l1 : i64

      %inner = eco.project %just_err[0] : !eco.value -> !eco.value
      eco.case %inner [0, 1] {
        // Err case - this should match
        %l2 = arith.constant 20 : i64
        eco.dbg %l2 : i64
        %err_payload = eco.project %inner[0] : !eco.value -> !eco.value
        eco.dbg %err_payload : !eco.value
        eco.return
      }, {
        %l2_ok = arith.constant 21 : i64
        eco.dbg %l2_ok : i64
        eco.return
      }
      eco.return
    }
    // Should print: 10, 20, 100
    // CHECK: [eco.dbg] 10
    // CHECK: [eco.dbg] 20
    // CHECK: [eco.dbg] 100

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
