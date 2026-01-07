// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test eco.safepoint inside a joinpoint body.
// Safepoints in loops are important for GC to interrupt long-running loops.
// This tests that safepoint operations work correctly within joinpoint regions.

module {
  func.func @main() -> i64 {
    %c0 = arith.constant 0 : i64
    %c1 = arith.constant 1 : i64
    %c42 = arith.constant 42 : i64

    // Test 1: Simple safepoint in joinpoint body
    eco.joinpoint 0(%n: i64) {
      // Safepoint - GC can interrupt here
      "eco.safepoint"() {stack_map = "n"} : () -> ()

      eco.dbg %n : i64
      eco.return
    } continuation {
      eco.jump 0(%c42 : i64)
    }
    // CHECK: [eco.dbg] 42

    // Test 2: Safepoint with multiple values in scope
    eco.joinpoint 1(%a: i64, %b: i64) {
      // Safepoint with multiple live values
      "eco.safepoint"() {stack_map = "a,b"} : () -> ()

      %sum = eco.int.add %a, %b : i64
      eco.dbg %sum : i64
      eco.return
    } continuation {
      %c10 = arith.constant 10 : i64
      %c20 = arith.constant 20 : i64
      eco.jump 1(%c10, %c20 : i64, i64)
    }
    // CHECK: [eco.dbg] 30

    // Test 3: Safepoint before case dispatch
    %c100 = arith.constant 100 : i64
    %b100 = eco.box %c100 : i64 -> !eco.value
    %tag0 = eco.construct.custom(%b100) {tag = 0 : i64, size = 1 : i64} : (!eco.value) -> !eco.value

    eco.joinpoint 2(%val: !eco.value) {
      // Safepoint before pattern matching
      "eco.safepoint"() {stack_map = "val"} : () -> ()

      eco.case %val [0, 1] {
        // Tag 0 branch
        %payload = eco.project.custom %val[0] : !eco.value -> !eco.value
        eco.dbg %payload : !eco.value
        eco.return
      }, {
        // Tag 1 branch - not taken
        %c999 = arith.constant 999 : i64
        eco.dbg %c999 : i64
        eco.return
      }
      eco.return
    } continuation {
      eco.jump 2(%tag0 : !eco.value)
    }
    // CHECK: [eco.dbg] 100

    // Test 4: Multiple safepoints in sequence
    eco.joinpoint 3(%x: i64) {
      // First safepoint
      "eco.safepoint"() {stack_map = "x"} : () -> ()

      %y = eco.int.add %x, %c1 : i64

      // Second safepoint
      "eco.safepoint"() {stack_map = "x,y"} : () -> ()

      %z = eco.int.add %y, %c1 : i64
      eco.dbg %z : i64
      eco.return
    } continuation {
      %c5 = arith.constant 5 : i64
      eco.jump 3(%c5 : i64)
    }
    // 5 + 1 + 1 = 7
    // CHECK: [eco.dbg] 7

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
