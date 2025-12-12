// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test direct function call with many arguments (10+).
// Tests argument marshalling at scale.

module {
  // Function that sums 10 boxed integers
  func.func @sum10(%a1: !eco.value, %a2: !eco.value, %a3: !eco.value,
                   %a4: !eco.value, %a5: !eco.value, %a6: !eco.value,
                   %a7: !eco.value, %a8: !eco.value, %a9: !eco.value,
                   %a10: !eco.value) -> !eco.value {
    %v1 = eco.unbox %a1 : !eco.value -> i64
    %v2 = eco.unbox %a2 : !eco.value -> i64
    %v3 = eco.unbox %a3 : !eco.value -> i64
    %v4 = eco.unbox %a4 : !eco.value -> i64
    %v5 = eco.unbox %a5 : !eco.value -> i64
    %v6 = eco.unbox %a6 : !eco.value -> i64
    %v7 = eco.unbox %a7 : !eco.value -> i64
    %v8 = eco.unbox %a8 : !eco.value -> i64
    %v9 = eco.unbox %a9 : !eco.value -> i64
    %v10 = eco.unbox %a10 : !eco.value -> i64

    %s1 = eco.int.add %v1, %v2 : i64
    %s2 = eco.int.add %s1, %v3 : i64
    %s3 = eco.int.add %s2, %v4 : i64
    %s4 = eco.int.add %s3, %v5 : i64
    %s5 = eco.int.add %s4, %v6 : i64
    %s6 = eco.int.add %s5, %v7 : i64
    %s7 = eco.int.add %s6, %v8 : i64
    %s8 = eco.int.add %s7, %v9 : i64
    %sum = eco.int.add %s8, %v10 : i64

    %result = eco.box %sum : i64 -> !eco.value
    eco.return %result : !eco.value
  }

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

    %b1 = eco.box %c1 : i64 -> !eco.value
    %b2 = eco.box %c2 : i64 -> !eco.value
    %b3 = eco.box %c3 : i64 -> !eco.value
    %b4 = eco.box %c4 : i64 -> !eco.value
    %b5 = eco.box %c5 : i64 -> !eco.value
    %b6 = eco.box %c6 : i64 -> !eco.value
    %b7 = eco.box %c7 : i64 -> !eco.value
    %b8 = eco.box %c8 : i64 -> !eco.value
    %b9 = eco.box %c9 : i64 -> !eco.value
    %b10 = eco.box %c10 : i64 -> !eco.value

    // Call sum10 using generic syntax: 1+2+3+4+5+6+7+8+9+10 = 55
    %sum = "eco.call"(%b1, %b2, %b3, %b4, %b5, %b6, %b7, %b8, %b9, %b10) {callee = @sum10} : (!eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value) -> !eco.value
    eco.dbg %sum : !eco.value
    // CHECK: [eco.dbg] 55

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
