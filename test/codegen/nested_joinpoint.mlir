// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test nested joinpoints - joinpoint inside another joinpoint's body.
// The inner joinpoint is in the body, not continuation, to maintain valid MLIR.

module {
  func.func @main() -> i64 {
    %c10 = arith.constant 10 : i64
    %c5 = arith.constant 5 : i64

    // Outer joinpoint
    eco.joinpoint 0(%x: i64) {
      // Body contains a nested joinpoint
      eco.joinpoint 1(%y: i64) {
        // Inner body: compute and return via outer exit
        %result = eco.int.mul %x, %y : i64
        eco.dbg %result : i64
        eco.return
      } continuation {
        // Inner continuation: jump to inner body with c5
        eco.jump 1(%c5 : i64)
      }
      // After nested joinpoint completes, outer returns
      eco.return
    } continuation {
      // Start: jump to outer body with c10
      eco.jump 0(%c10 : i64)
    }
    // Flow: jump 0(10) -> outer body -> jump 1(5) -> inner body -> 10*5=50 -> return
    // CHECK: 50

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
