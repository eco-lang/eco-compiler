// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test eco.case inside joinpoint body.
// Tests that CaseOp lowering correctly handles scrutinee operands that have
// been type-converted (e.g., inside a joinpoint where !eco.value -> i64).
//
// Use case: A continuation that needs to pattern match on its argument.
// Example Elm: let result = ... in case result of A -> ... | B -> ...

module {
  func.func @main() -> i64 {
    %c1 = arith.constant 1 : i64
    %c2 = arith.constant 2 : i64
    %b1 = eco.box %c1 : i64 -> !eco.value
    %b2 = eco.box %c2 : i64 -> !eco.value

    // Create tagged objects
    // Tag 0 = "Left" variant
    %left = eco.construct(%b1) {tag = 0 : i64, size = 1 : i64} : (!eco.value) -> !eco.value
    // Tag 1 = "Right" variant
    %right = eco.construct(%b2) {tag = 1 : i64, size = 1 : i64} : (!eco.value) -> !eco.value

    // Joinpoint where the body needs to case-dispatch on the argument
    eco.joinpoint 0(%val: !eco.value) {
      // This case dispatch inside joinpoint body causes the crash
      eco.case %val [0, 1] {
        // Tag 0 (Left) branch: return the payload
        %payload = eco.project %val[0] : !eco.value -> !eco.value
        eco.dbg %payload : !eco.value
        eco.return
      }, {
        // Tag 1 (Right) branch: return payload * 10
        %payload = eco.project %val[0] : !eco.value -> !eco.value
        %unboxed = eco.unbox %payload : !eco.value -> i64
        %c10 = arith.constant 10 : i64
        %result = eco.int.mul %unboxed, %c10 : i64
        eco.dbg %result : i64
        eco.return
      }
      eco.return
    } continuation {
      // Jump with the Left variant
      eco.jump 0(%left : !eco.value)
    }
    // Expected: 1
    // CHECK: 1

    // Second test with Right variant
    eco.joinpoint 1(%val2: !eco.value) {
      eco.case %val2 [0, 1] {
        %c100 = arith.constant 100 : i64
        eco.dbg %c100 : i64
        eco.return
      }, {
        %c200 = arith.constant 200 : i64
        eco.dbg %c200 : i64
        eco.return
      }
      eco.return
    } continuation {
      eco.jump 1(%right : !eco.value)
    }
    // Expected: 200
    // CHECK: 200

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
