// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test joinpoint defined with case inside its body.
// Complex nesting interaction.

module {
  func.func @main() -> i64 {
    %unit = eco.constant Unit : !eco.value
    %tag0 = eco.construct(%unit) {tag = 0 : i64, size = 1 : i64} : (!eco.value) -> !eco.value
    %tag1 = eco.construct(%unit) {tag = 1 : i64, size = 1 : i64} : (!eco.value) -> !eco.value

    // Joinpoint that does a case dispatch (tag 0)
    eco.joinpoint 0(%val: !eco.value) {
      eco.case %val [0, 1] {
        %c100 = arith.constant 100 : i64
        eco.dbg %c100 : i64
        eco.return
      }, {
        %c200 = arith.constant 200 : i64
        eco.dbg %c200 : i64
        eco.return
      }
      eco.return
    } continuation {
      eco.jump 0(%tag0 : !eco.value)
    }
    // CHECK: [eco.dbg] 100

    // Another joinpoint that does case dispatch (tag 1)
    eco.joinpoint 1(%val2: !eco.value) {
      eco.case %val2 [0, 1] {
        %c300 = arith.constant 300 : i64
        eco.dbg %c300 : i64
        eco.return
      }, {
        %c400 = arith.constant 400 : i64
        eco.dbg %c400 : i64
        eco.return
      }
      eco.return
    } continuation {
      eco.jump 1(%tag1 : !eco.value)
    }
    // CHECK: [eco.dbg] 400

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
