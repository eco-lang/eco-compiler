// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test joinpoint with multiple argument types: i64, f64, i16, and !eco.value.
// This tests type conversion handling in joinpoint argument passing.

module {
  func.func @main() -> i64 {
    %int_val = arith.constant 42 : i64
    %float_val = arith.constant 3.14 : f64
    %char_val = arith.constant 65 : i16  // 'A'
    %boxed = eco.box %int_val : i64 -> !eco.value

    // Joinpoint with mixed argument types
    eco.joinpoint 0(%i: i64, %f: f64, %c: i16, %v: !eco.value) {
      // Use all the arguments
      eco.dbg %i : i64
      // CHECK: 42

      eco.dbg %f : f64
      // CHECK: 3.14

      eco.dbg %c : i16
      // CHECK: 'A'

      eco.dbg %v : !eco.value
      // eco.dbg on !eco.value prints the address, not the value

      eco.return
    } continuation {
      eco.jump 0(%int_val, %float_val, %char_val, %boxed : i64, f64, i16, !eco.value)
    }

    // Test 2: Joinpoint with f64 argument
    %float_sum = arith.constant 100.5 : f64

    eco.joinpoint 1(%f: f64) {
      eco.dbg %f : f64
      eco.return
    } continuation {
      eco.jump 1(%float_sum : f64)
    }
    // CHECK: 100.5

    %ret = arith.constant 0 : i64
    return %ret : i64
  }
}
