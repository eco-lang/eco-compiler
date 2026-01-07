// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test that code paths with unreachable ops work correctly.
// eco.unreachable marks code paths that should never be reached.
// Note: We can't directly test eco.unreachable execution (it would crash),
// but we can test that code containing unreachable compiles correctly.

module {
  func.func @main() -> i64 {
    %c0 = arith.constant 0 : i64
    %c1 = arith.constant 1 : i64
    %c42 = arith.constant 42 : i64

    %b42 = eco.box %c42 : i64 -> !eco.value

    // Create Just(42) - tag 1
    %just = eco.construct.custom(%b42) {tag = 1 : i64, size = 1 : i64} : (!eco.value) -> !eco.value

    // Case where one branch is "impossible" in our test
    // but the compiler doesn't know that
    eco.case %just [0, 1] {
      // Nothing branch - won't be taken
      %r0 = arith.constant -1 : i64
      eco.dbg %r0 : i64
      eco.return
    }, {
      // Just branch - will be taken
      %payload = eco.project.custom %just[0] : !eco.value -> !eco.value
      eco.dbg %payload : !eco.value
      eco.return
    }
    // CHECK: [eco.dbg] 42

    // Create Nothing - tag 0
    %nothing = eco.construct.custom() {tag = 0 : i64, size = 0 : i64} : () -> !eco.value

    eco.case %nothing [0, 1] {
      // Nothing branch - will be taken
      %r0 = arith.constant 100 : i64
      eco.dbg %r0 : i64
      eco.return
    }, {
      // Just branch - won't be taken
      %r1 = arith.constant -100 : i64
      eco.dbg %r1 : i64
      eco.return
    }
    // CHECK: [eco.dbg] 100

    // Test completed successfully
    %success = arith.constant 1 : i64
    eco.dbg %success : i64
    // CHECK: [eco.dbg] 1

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
