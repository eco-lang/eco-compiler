// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test joinpoint passing boxed values via i64 (tagged pointers).
// Note: !eco.value arguments in joinpoints are lowered to i64, so we use that directly.

module {
  func.func @main() -> i64 {
    %i10 = arith.constant 10 : i64
    %i20 = arith.constant 20 : i64
    %i30 = arith.constant 30 : i64

    // Joinpoint with single i64 argument
    eco.joinpoint 0(%val: i64) {
      eco.dbg %val : i64
      eco.return
    } continuation {
      eco.jump 0(%i10 : i64)
    }
    // CHECK: 10

    // Joinpoint with two i64 arguments
    eco.joinpoint 1(%a: i64, %b: i64) {
      eco.dbg %a : i64
      eco.dbg %b : i64
      %sum = eco.int.add %a, %b : i64
      eco.dbg %sum : i64
      eco.return
    } continuation {
      eco.jump 1(%i10, %i20 : i64, i64)
    }
    // CHECK: 10
    // CHECK: 20
    // CHECK: 30

    // Joinpoint that computes product of two args
    eco.joinpoint 2(%x: i64, %y: i64) {
      %product = eco.int.mul %x, %y : i64
      eco.dbg %product : i64
      eco.return
    } continuation {
      eco.jump 2(%i10, %i30 : i64, i64)
    }
    // 10 * 30 = 300
    // CHECK: 300

    // Joinpoint with three arguments
    eco.joinpoint 3(%p: i64, %q: i64, %r: i64) {
      %sum1 = eco.int.add %p, %q : i64
      %sum2 = eco.int.add %sum1, %r : i64
      eco.dbg %sum2 : i64
      eco.return
    } continuation {
      eco.jump 3(%i10, %i20, %i30 : i64, i64, i64)
    }
    // 10 + 20 + 30 = 60
    // CHECK: 60

    // Joinpoint with computed value
    eco.joinpoint 4(%n: i64) {
      %squared = eco.int.mul %n, %n : i64
      eco.dbg %squared : i64
      eco.return
    } continuation {
      %c7 = arith.constant 7 : i64
      eco.jump 4(%c7 : i64)
    }
    // 7 * 7 = 49
    // CHECK: 49

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
