// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test control flow composition: computation inside joinpoint bodies.

module {
  func.func @main() -> i64 {
    %c10 = arith.constant 10 : i64
    %c20 = arith.constant 20 : i64

    // Joinpoint that computes x * x
    eco.joinpoint 0(%x: i64) {
      %squared = eco.int.mul %x, %x : i64
      eco.dbg %squared : i64
      eco.return
    } continuation {
      eco.jump 0(%c10 : i64)
    }
    // 10 * 10 = 100
    // CHECK: 100

    // Joinpoint with multiple args that computes sum and product
    eco.joinpoint 1(%a: i64, %b: i64) {
      %sum = eco.int.add %a, %b : i64
      %product = eco.int.mul %a, %b : i64
      eco.dbg %sum : i64
      eco.dbg %product : i64
      eco.return
    } continuation {
      eco.jump 1(%c10, %c20 : i64, i64)
    }
    // 10 + 20 = 30
    // 10 * 20 = 200
    // CHECK: 30
    // CHECK: 200

    // Joinpoint that computes cubic value
    eco.joinpoint 2(%n: i64) {
      %n2 = eco.int.mul %n, %n : i64
      %n3 = eco.int.mul %n2, %n : i64
      eco.dbg %n3 : i64
      eco.return
    } continuation {
      %c3 = arith.constant 3 : i64
      eco.jump 2(%c3 : i64)
    }
    // 3^3 = 27
    // CHECK: 27

    // Joinpoint with subtraction
    eco.joinpoint 3(%p: i64, %q: i64) {
      %diff = eco.int.sub %p, %q : i64
      eco.dbg %diff : i64
      eco.return
    } continuation {
      %c50 = arith.constant 50 : i64
      %c30 = arith.constant 30 : i64
      eco.jump 3(%c50, %c30 : i64, i64)
    }
    // 50 - 30 = 20
    // CHECK: 20

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
