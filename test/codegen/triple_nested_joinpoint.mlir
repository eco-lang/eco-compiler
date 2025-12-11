// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test three levels of nested joinpoints.
// Tests deep recursion in joinpoint lowering.

module {
  func.func @main() -> i64 {
    %c2 = arith.constant 2 : i64
    %c3 = arith.constant 3 : i64
    %c5 = arith.constant 5 : i64

    // Outermost joinpoint
    eco.joinpoint 0(%x: i64) {
      // Middle joinpoint
      eco.joinpoint 1(%y: i64) {
        // Innermost joinpoint
        eco.joinpoint 2(%z: i64) {
          // Compute x * y * z
          %xy = eco.int.mul %x, %y : i64
          %xyz = eco.int.mul %xy, %z : i64
          eco.dbg %xyz : i64
          eco.return
        } continuation {
          eco.jump 2(%c5 : i64)
        }
        eco.return
      } continuation {
        eco.jump 1(%c3 : i64)
      }
      eco.return
    } continuation {
      eco.jump 0(%c2 : i64)
    }
    // 2 * 3 * 5 = 30
    // CHECK: 30

    // Another test: nested with different jump patterns
    %c10 = arith.constant 10 : i64

    eco.joinpoint 10(%a: i64) {
      eco.joinpoint 11(%b: i64) {
        eco.joinpoint 12(%c: i64) {
          // Sum all three
          %ab = eco.int.add %a, %b : i64
          %abc = eco.int.add %ab, %c : i64
          eco.dbg %abc : i64
          eco.return
        } continuation {
          %c100 = arith.constant 100 : i64
          eco.jump 12(%c100 : i64)
        }
        eco.return
      } continuation {
        %c20 = arith.constant 20 : i64
        eco.jump 11(%c20 : i64)
      }
      eco.return
    } continuation {
      eco.jump 10(%c10 : i64)
    }
    // 10 + 20 + 100 = 130
    // CHECK: 130

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
