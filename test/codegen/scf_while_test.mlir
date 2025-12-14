// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test scf.while lowering for list traversal patterns.
// This tests the JoinpointToScfWhilePattern which converts canonical
// loop patterns to scf.while.

module {
  func.func @main() -> i64 {
    %c0 = arith.constant 0 : i64
    %c1 = arith.constant 1 : i64
    %c2 = arith.constant 2 : i64
    %c3 = arith.constant 3 : i64

    // Create boxed values
    %b1 = eco.box %c1 : i64 -> !eco.value
    %b2 = eco.box %c2 : i64 -> !eco.value
    %b3 = eco.box %c3 : i64 -> !eco.value

    // Build a list: [1, 2, 3]
    // Nil = tag 0, size 0
    // Cons(head, tail) = tag 1, size 2
    %nil = eco.construct() {tag = 0 : i64, size = 0 : i64} : () -> !eco.value
    %cons3 = eco.construct(%b3, %nil) {tag = 1 : i64, size = 2 : i64} : (!eco.value, !eco.value) -> !eco.value
    %cons2 = eco.construct(%b2, %cons3) {tag = 1 : i64, size = 2 : i64} : (!eco.value, !eco.value) -> !eco.value
    %cons1 = eco.construct(%b1, %cons2) {tag = 1 : i64, size = 2 : i64} : (!eco.value, !eco.value) -> !eco.value

    // Test 1: Count list length using a loop
    // This is the canonical "fold" pattern that should lower to scf.while
    eco.joinpoint 0(%list: !eco.value, %acc: i64) {
      eco.case %list [0, 1] {
        // Nil case: return the accumulated count
        eco.dbg %acc : i64
        eco.return
      }, {
        // Cons case: increment count and continue with tail
        %tail = eco.project %list[1] : !eco.value -> !eco.value
        %new_acc = arith.addi %acc, %c1 : i64
        eco.jump 0(%tail, %new_acc : !eco.value, i64)
      }
      eco.return
    } continuation {
      eco.jump 0(%cons1, %c0 : !eco.value, i64)
    }
    // Expected: 3 (length of [1, 2, 3])
    // CHECK: 3

    // Test 2: Sum list elements
    eco.joinpoint 1(%list2: !eco.value, %sum: i64) {
      eco.case %list2 [0, 1] {
        // Nil case: return the sum
        eco.dbg %sum : i64
        eco.return
      }, {
        // Cons case: add head to sum and continue with tail
        %head = eco.project %list2[0] : !eco.value -> !eco.value
        %head_val = eco.unbox %head : !eco.value -> i64
        %new_sum = arith.addi %sum, %head_val : i64
        %tail2 = eco.project %list2[1] : !eco.value -> !eco.value
        eco.jump 1(%tail2, %new_sum : !eco.value, i64)
      }
      eco.return
    } continuation {
      eco.jump 1(%cons1, %c0 : !eco.value, i64)
    }
    // Expected: 6 (sum of [1, 2, 3])
    // CHECK: 6

    // Test 3: Simple list traversal (no accumulator, just traverse)
    eco.joinpoint 2(%list3: !eco.value) {
      eco.case %list3 [0, 1] {
        // Nil case: done
        eco.dbg %c0 : i64  // Print 0 to indicate done
        eco.return
      }, {
        // Cons case: print head and continue
        %head3 = eco.project %list3[0] : !eco.value -> !eco.value
        eco.dbg %head3 : !eco.value
        %tail3 = eco.project %list3[1] : !eco.value -> !eco.value
        eco.jump 2(%tail3 : !eco.value)
      }
      eco.return
    } continuation {
      eco.jump 2(%cons1 : !eco.value)
    }
    // Expected: 1, 2, 3, 0 (traverse list then print 0)
    // CHECK: 1
    // CHECK: 2
    // CHECK: 3
    // CHECK: 0

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
