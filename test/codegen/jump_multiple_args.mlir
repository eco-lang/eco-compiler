// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test eco.jump with multiple arguments.

module {
  func.func @main() -> i64 {
    %c0 = arith.constant 0 : i64
    %c10 = arith.constant 10 : i64
    %c20 = arith.constant 20 : i64
    %c30 = arith.constant 30 : i64

    // Joinpoint with two arguments
    eco.joinpoint 0(%a: i64, %b: i64) {
      %sum = eco.int.add %a, %b : i64
      eco.dbg %sum : i64
      eco.return
    } continuation {
      eco.jump 0(%c10, %c20 : i64, i64)
    }
    // CHECK: 30

    // Joinpoint with three arguments
    eco.joinpoint 1(%x: i64, %y: i64, %z: i64) {
      %sum1 = eco.int.add %x, %y : i64
      %sum2 = eco.int.add %sum1, %z : i64
      eco.dbg %sum2 : i64
      eco.return
    } continuation {
      eco.jump 1(%c10, %c20, %c30 : i64, i64, i64)
    }
    // CHECK: 60

    // Joinpoint with 4 arguments
    %c1 = arith.constant 1 : i64
    %c2 = arith.constant 2 : i64
    %c3 = arith.constant 3 : i64
    %c4 = arith.constant 4 : i64
    eco.joinpoint 2(%a1: i64, %a2: i64, %a3: i64, %a4: i64) {
      %s1 = eco.int.add %a1, %a2 : i64
      %s2 = eco.int.add %s1, %a3 : i64
      %s3 = eco.int.add %s2, %a4 : i64
      eco.dbg %s3 : i64
      eco.return
    } continuation {
      eco.jump 2(%c1, %c2, %c3, %c4 : i64, i64, i64, i64)
    }
    // 1 + 2 + 3 + 4 = 10
    // CHECK: 10

    // Joinpoint with 5 arguments
    %c5 = arith.constant 5 : i64
    eco.joinpoint 3(%b1: i64, %b2: i64, %b3: i64, %b4: i64, %b5: i64) {
      %t1 = eco.int.add %b1, %b2 : i64
      %t2 = eco.int.add %t1, %b3 : i64
      %t3 = eco.int.add %t2, %b4 : i64
      %t4 = eco.int.add %t3, %b5 : i64
      eco.dbg %t4 : i64
      eco.return
    } continuation {
      eco.jump 3(%c1, %c2, %c3, %c4, %c5 : i64, i64, i64, i64, i64)
    }
    // 1 + 2 + 3 + 4 + 5 = 15
    // CHECK: 15

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
