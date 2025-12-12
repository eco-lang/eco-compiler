// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test joinpoint with many arguments (10).
// Tests argument passing scalability.

module {
  func.func @main() -> i64 {
    %c1 = arith.constant 1 : i64
    %c2 = arith.constant 2 : i64
    %c3 = arith.constant 3 : i64
    %c4 = arith.constant 4 : i64
    %c5 = arith.constant 5 : i64
    %c6 = arith.constant 6 : i64
    %c7 = arith.constant 7 : i64
    %c8 = arith.constant 8 : i64
    %c9 = arith.constant 9 : i64
    %c10 = arith.constant 10 : i64

    // Joinpoint with 10 arguments
    eco.joinpoint 0(%a: i64, %b: i64, %c: i64, %d: i64, %e: i64,
                    %f: i64, %g: i64, %h: i64, %i: i64, %j: i64) {
      %s1 = eco.int.add %a, %b : i64
      %s2 = eco.int.add %s1, %c : i64
      %s3 = eco.int.add %s2, %d : i64
      %s4 = eco.int.add %s3, %e : i64
      %s5 = eco.int.add %s4, %f : i64
      %s6 = eco.int.add %s5, %g : i64
      %s7 = eco.int.add %s6, %h : i64
      %s8 = eco.int.add %s7, %i : i64
      %s9 = eco.int.add %s8, %j : i64
      eco.dbg %s9 : i64
      eco.return
    } continuation {
      eco.jump 0(%c1, %c2, %c3, %c4, %c5, %c6, %c7, %c8, %c9, %c10 : i64, i64, i64, i64, i64, i64, i64, i64, i64, i64)
    }
    // CHECK: [eco.dbg] 55

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
