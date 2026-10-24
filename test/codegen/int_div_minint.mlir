// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test integer division edge cases with INT64_MIN.
// INT64_MIN / -1 overflows (INT64_MAX + 1); Elm Int wraps, so the result is
// INT64_MIN and both remainders by -1 are 0 (CGEN_084).

module {
  func.func @main() -> i64 {
    %min_int = arith.constant -9223372036854775808 : i64  // INT64_MIN
    %neg1 = arith.constant -1 : i64
    %pos1 = arith.constant 1 : i64
    %neg2 = arith.constant -2 : i64

    // INT64_MIN / 1 = INT64_MIN (no overflow)
    %div1 = eco.int.div %min_int, %pos1 : i64
    eco.dbg %div1 : i64
    // CHECK: [eco.dbg] -9223372036854775808{{$}}

    // INT64_MIN / -2 = INT64_MIN / 2 with sign = 4611686018427387904
    %div2 = eco.int.div %min_int, %neg2 : i64
    eco.dbg %div2 : i64
    // CHECK-NEXT: [eco.dbg] 4611686018427387904{{$}}

    // INT64_MIN / -1 = INT64_MAX + 1, which wraps to INT64_MIN
    %div_overflow = eco.int.div %min_int, %neg1 : i64
    eco.dbg %div_overflow : i64
    // CHECK-NEXT: [eco.dbg] -9223372036854775808{{$}}

    // INT64_MIN % -1 = 0 (no remainder regardless of overflow)
    %rem = eco.int.remainderby %neg1, %min_int : i64
    eco.dbg %rem : i64
    // CHECK-NEXT: [eco.dbg] 0{{$}}

    // INT64_MIN % -2 = 0
    %rem2 = eco.int.remainderby %neg2, %min_int : i64
    eco.dbg %rem2 : i64
    // CHECK-NEXT: [eco.dbg] 0{{$}}

    // modBy -1 INT64_MIN = 0
    %mod = eco.int.modby %neg1, %min_int : i64
    eco.dbg %mod : i64
    // CHECK-NEXT: [eco.dbg] 0{{$}}

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
