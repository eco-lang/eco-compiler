// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test sequential joinpoints (nested joinpoints are complex, test sequential instead).
// Each joinpoint is independent but tests the joinpoint mechanism thoroughly.

module {
  func.func @main() -> i64 {
    %c0 = arith.constant 0 : i64
    %c1 = arith.constant 1 : i64
    %c5 = arith.constant 5 : i64
    %c7 = arith.constant 7 : i64
    %c3 = arith.constant 3 : i64

    // First joinpoint - simple print
    eco.joinpoint 0(%val1: i64) {
      eco.dbg %val1 : i64
      eco.return
    } continuation {
      eco.jump 0(%c5 : i64)
    }
    // CHECK: 5

    // Second joinpoint - compute square
    eco.joinpoint 1(%val2: i64) {
      %squared = eco.int.mul %val2, %val2 : i64
      eco.dbg %squared : i64
      eco.return
    } continuation {
      eco.jump 1(%c5 : i64)
    }
    // 5 * 5 = 25
    // CHECK: 25

    // Third joinpoint - sum of two args
    eco.joinpoint 2(%a: i64, %b: i64) {
      %sum = eco.int.add %a, %b : i64
      eco.dbg %sum : i64
      eco.return
    } continuation {
      eco.jump 2(%c7, %c3 : i64, i64)
    }
    // 7 + 3 = 10
    // CHECK: 10

    // Fourth joinpoint - nested computation
    eco.joinpoint 3(%x: i64) {
      %doubled = eco.int.add %x, %x : i64
      %tripled = eco.int.add %doubled, %x : i64
      eco.dbg %tripled : i64
      eco.return
    } continuation {
      eco.jump 3(%c5 : i64)
    }
    // 5 + 5 + 5 = 15
    // CHECK: 15

    // Fifth joinpoint - product of three args
    eco.joinpoint 4(%p: i64, %q: i64, %r: i64) {
      %pq = eco.int.mul %p, %q : i64
      %result = eco.int.mul %pq, %r : i64
      eco.dbg %result : i64
      eco.return
    } continuation {
      %c2 = arith.constant 2 : i64
      %c4 = arith.constant 4 : i64
      eco.jump 4(%c2, %c3, %c4 : i64, i64, i64)
    }
    // 2 * 3 * 4 = 24
    // CHECK: 24

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
