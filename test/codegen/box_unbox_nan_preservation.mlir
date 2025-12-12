// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test that NaN bit patterns are preserved through box/unbox.
// Different NaN encodings should roundtrip correctly.

module {
  func.func @main() -> i64 {
    %f0 = arith.constant 0.0 : f64

    // Create NaN via 0/0
    %nan1 = arith.divf %f0, %f0 : f64

    // Box and unbox
    %boxed1 = eco.box %nan1 : f64 -> !eco.value
    %unboxed1 = eco.unbox %boxed1 : !eco.value -> f64

    // NaN should still be NaN after roundtrip (NaN != NaN)
    %is_nan1 = eco.float.cmp eq %unboxed1, %unboxed1 : f64
    %is_nan1_i = arith.extui %is_nan1 : i1 to i64
    eco.dbg %is_nan1_i : i64
    // CHECK: [eco.dbg] 0

    // Create a specific NaN pattern via bitcast
    // Quiet NaN: 0x7FF8000000000000
    %qnan_bits = arith.constant 0x7FF8000000000000 : i64
    %qnan = arith.bitcast %qnan_bits : i64 to f64

    // Box and unbox
    %boxed_qnan = eco.box %qnan : f64 -> !eco.value
    %unboxed_qnan = eco.unbox %boxed_qnan : !eco.value -> f64

    // Should still be NaN
    %is_qnan = eco.float.cmp eq %unboxed_qnan, %unboxed_qnan : f64
    %is_qnan_i = arith.extui %is_qnan : i1 to i64
    eco.dbg %is_qnan_i : i64
    // CHECK: [eco.dbg] 0

    // Signaling NaN pattern: 0x7FF0000000000001
    %snan_bits = arith.constant 0x7FF0000000000001 : i64
    %snan = arith.bitcast %snan_bits : i64 to f64

    // Box and unbox
    %boxed_snan = eco.box %snan : f64 -> !eco.value
    %unboxed_snan = eco.unbox %boxed_snan : !eco.value -> f64

    // Should still be NaN
    %is_snan = eco.float.cmp eq %unboxed_snan, %unboxed_snan : f64
    %is_snan_i = arith.extui %is_snan : i1 to i64
    eco.dbg %is_snan_i : i64
    // CHECK: [eco.dbg] 0

    // Negative NaN: 0xFFF8000000000000
    %neg_nan_bits = arith.constant 0xFFF8000000000000 : i64
    %neg_nan = arith.bitcast %neg_nan_bits : i64 to f64

    // Box and unbox
    %boxed_neg_nan = eco.box %neg_nan : f64 -> !eco.value
    %unboxed_neg_nan = eco.unbox %boxed_neg_nan : !eco.value -> f64

    // Should still be NaN
    %is_neg_nan = eco.float.cmp eq %unboxed_neg_nan, %unboxed_neg_nan : f64
    %is_neg_nan_i = arith.extui %is_neg_nan : i1 to i64
    eco.dbg %is_neg_nan_i : i64
    // CHECK: [eco.dbg] 0

    // Verify a normal value still works
    %f42 = arith.constant 42.5 : f64
    %boxed_normal = eco.box %f42 : f64 -> !eco.value
    %unboxed_normal = eco.unbox %boxed_normal : !eco.value -> f64
    %is_normal = eco.float.cmp eq %unboxed_normal, %f42 : f64
    %is_normal_i = arith.extui %is_normal : i1 to i64
    eco.dbg %is_normal_i : i64
    // CHECK: [eco.dbg] 1

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
