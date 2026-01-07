// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
// XFAIL: *
//
// Test jump to outer joinpoint from inside a case branch.
// Complex control flow unwinding across case and joinpoint boundaries.
//
// XFAIL REASON: eco.case regions must end with eco.return, not eco.jump.
// This is a design constraint of the eco.case op.

module {
  func.func @main() -> i64 {
    %unit = eco.constant Unit : !eco.value

    // Create variants
    %tag0 = eco.construct.custom(%unit) {tag = 0 : i64, size = 1 : i64} : (!eco.value) -> !eco.value
    %tag1 = eco.construct.custom(%unit) {tag = 1 : i64, size = 1 : i64} : (!eco.value) -> !eco.value
    %tag2 = eco.construct.custom(%unit) {tag = 2 : i64, size = 1 : i64} : (!eco.value) -> !eco.value

    // Outer joinpoint that accumulates a result
    eco.joinpoint 0(%result: i64) {
      eco.dbg %result : i64
      eco.return
    } continuation {
      // Case dispatch that jumps to the outer joinpoint from different branches
      eco.case %tag1 [0, 1, 2] {
        // Tag 0: jump with 100
        %c100 = arith.constant 100 : i64
        eco.jump 0(%c100 : i64)
      }, {
        // Tag 1: do some computation then jump
        %c200 = arith.constant 200 : i64
        %c50 = arith.constant 50 : i64
        %sum = eco.int.add %c200, %c50 : i64
        eco.jump 0(%sum : i64)
      }, {
        // Tag 2: jump with 300
        %c300 = arith.constant 300 : i64
        eco.jump 0(%c300 : i64)
      }
      eco.return
    }
    // Tag 1 selected: 200 + 50 = 250
    // CHECK: 250

    // Second test: jump from nested case
    eco.joinpoint 1(%result2: i64) {
      eco.dbg %result2 : i64
      eco.return
    } continuation {
      eco.case %tag0 [0, 1, 2] {
        // Tag 0 branch: nested case
        eco.case %tag2 [0, 1, 2] {
          %c1 = arith.constant 1 : i64
          eco.jump 1(%c1 : i64)
        }, {
          %c2 = arith.constant 2 : i64
          eco.jump 1(%c2 : i64)
        }, {
          // This branch executes (tag2 has tag=2)
          %c3 = arith.constant 3 : i64
          eco.jump 1(%c3 : i64)
        }
        eco.return
      }, {
        %c10 = arith.constant 10 : i64
        eco.jump 1(%c10 : i64)
      }, {
        %c20 = arith.constant 20 : i64
        eco.jump 1(%c20 : i64)
      }
      eco.return
    }
    // tag0 has tag=0, so first branch executes
    // Inside, tag2 has tag=2, so third inner branch: result = 3
    // CHECK: 3

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
