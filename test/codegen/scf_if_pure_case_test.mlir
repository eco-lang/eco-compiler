// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test scf.if lowering for PURE case expressions (all alternatives end with eco.return).
// These tests use joinpoints WITHOUT fallback returns (since all case branches return).

module {
  func.func @main() -> i64 {
    %c0 = arith.constant 0 : i64
    %c10 = arith.constant 10 : i64
    %c20 = arith.constant 20 : i64
    %c30 = arith.constant 30 : i64

    // True = tag 1, False = tag 0
    %true = eco.construct() {tag = 1 : i64, size = 0 : i64} : () -> !eco.value
    %false = eco.construct() {tag = 0 : i64, size = 0 : i64} : () -> !eco.value

    // Test 1: Simple case dispatch (true branch)
    eco.joinpoint 1(%v: !eco.value) {
      eco.case %v [0, 1] {
        eco.dbg %c20 : i64
        eco.return
      }, {
        eco.dbg %c10 : i64
        eco.return
      }
      eco.return  // Note: eco.case is control flow, this return is reachable
    } continuation {
      eco.jump 1(%true : !eco.value)
    }
    // CHECK: 10

    // Test 2: Simple case dispatch (false branch)
    eco.joinpoint 2(%v: !eco.value) {
      eco.case %v [0, 1] {
        eco.dbg %c20 : i64
        eco.return
      }, {
        eco.dbg %c10 : i64
        eco.return
      }
      eco.return
    } continuation {
      eco.jump 2(%false : !eco.value)
    }
    // CHECK: 20

    // Test 3: List sum
    %nil = eco.construct() {tag = 0 : i64, size = 0 : i64} : () -> !eco.value
    %b10 = eco.box %c10 : i64 -> !eco.value
    %b20 = eco.box %c20 : i64 -> !eco.value
    %cons2 = eco.construct(%b20, %nil) {tag = 1 : i64, size = 2 : i64} : (!eco.value, !eco.value) -> !eco.value
    %cons1 = eco.construct(%b10, %cons2) {tag = 1 : i64, size = 2 : i64} : (!eco.value, !eco.value) -> !eco.value

    eco.joinpoint 3(%list: !eco.value, %sum: i64) {
      eco.case %list [0, 1] {
        eco.dbg %sum : i64
        eco.return
      }, {
        %head = eco.project %list[0] : !eco.value -> !eco.value
        %head_val = eco.unbox %head : !eco.value -> i64
        %new_sum = arith.addi %sum, %head_val : i64
        %tail = eco.project %list[1] : !eco.value -> !eco.value
        eco.jump 3(%tail, %new_sum : !eco.value, i64)
      }
      eco.return
    } continuation {
      eco.jump 3(%cons1, %c0 : !eco.value, i64)
    }
    // CHECK: 30

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
