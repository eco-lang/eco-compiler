// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test eco.int.cmp with values near INT64_MAX and INT64_MIN.
// Ensures signed comparison is used correctly.

module {
  func.func @main() -> i64 {
    %int_max = arith.constant 9223372036854775807 : i64  // INT64_MAX
    %int_min = arith.constant -9223372036854775808 : i64 // INT64_MIN
    %c0 = arith.constant 0 : i64
    %c1 = arith.constant 1 : i64
    %cn1 = arith.constant -1 : i64

    // INT64_MAX > 0 (should be true with signed comparison)
    %cmp1 = eco.int.cmp gt %int_max, %c0 : i64
    %i1 = arith.extui %cmp1 : i1 to i64
    eco.dbg %i1 : i64
    // CHECK: [eco.dbg] 1

    // INT64_MIN < 0 (should be true with signed comparison)
    %cmp2 = eco.int.cmp lt %int_min, %c0 : i64
    %i2 = arith.extui %cmp2 : i1 to i64
    eco.dbg %i2 : i64
    // CHECK: [eco.dbg] 1

    // INT64_MIN < INT64_MAX (should be true)
    %cmp3 = eco.int.cmp lt %int_min, %int_max : i64
    %i3 = arith.extui %cmp3 : i1 to i64
    eco.dbg %i3 : i64
    // CHECK: [eco.dbg] 1

    // INT64_MAX > INT64_MIN (should be true)
    %cmp4 = eco.int.cmp gt %int_max, %int_min : i64
    %i4 = arith.extui %cmp4 : i1 to i64
    eco.dbg %i4 : i64
    // CHECK: [eco.dbg] 1

    // -1 > INT64_MIN (should be true)
    %cmp5 = eco.int.cmp gt %cn1, %int_min : i64
    %i5 = arith.extui %cmp5 : i1 to i64
    eco.dbg %i5 : i64
    // CHECK: [eco.dbg] 1

    // -1 < INT64_MAX (should be true)
    %cmp6 = eco.int.cmp lt %cn1, %int_max : i64
    %i6 = arith.extui %cmp6 : i1 to i64
    eco.dbg %i6 : i64
    // CHECK: [eco.dbg] 1

    // INT64_MAX >= INT64_MAX (should be true)
    %cmp7 = eco.int.cmp ge %int_max, %int_max : i64
    %i7 = arith.extui %cmp7 : i1 to i64
    eco.dbg %i7 : i64
    // CHECK: [eco.dbg] 1

    // INT64_MIN <= INT64_MIN (should be true)
    %cmp8 = eco.int.cmp le %int_min, %int_min : i64
    %i8 = arith.extui %cmp8 : i1 to i64
    eco.dbg %i8 : i64
    // CHECK: [eco.dbg] 1

    // INT64_MAX != INT64_MIN (should be true)
    %cmp9 = eco.int.cmp ne %int_max, %int_min : i64
    %i9 = arith.extui %cmp9 : i1 to i64
    eco.dbg %i9 : i64
    // CHECK: [eco.dbg] 1

    // INT64_MAX == INT64_MAX (should be true)
    %cmp10 = eco.int.cmp eq %int_max, %int_max : i64
    %i10 = arith.extui %cmp10 : i1 to i64
    eco.dbg %i10 : i64
    // CHECK: [eco.dbg] 1

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
