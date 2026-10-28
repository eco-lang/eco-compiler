// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test box/unbox with extreme values.

module {
  func.func @main() -> i64 {
    // INT64_MAX
    %int_max = arith.constant 9223372036854775807 : i64
    %box_max = eco.box %int_max : i64 -> !eco.value
    %unbox_max = eco.unbox %box_max : !eco.value -> i64
    eco.dbg %unbox_max : i64
    // CHECK: 9223372036854775807

    // INT64_MIN
    %int_min = arith.constant -9223372036854775808 : i64
    %box_min = eco.box %int_min : i64 -> !eco.value
    %unbox_min = eco.unbox %box_min : !eco.value -> i64
    eco.dbg %unbox_min : i64
    // CHECK: -9223372036854775808

    // Zero
    %zero_i = arith.constant 0 : i64
    %box_zero = eco.box %zero_i : i64 -> !eco.value
    %unbox_zero = eco.unbox %box_zero : !eco.value -> i64
    eco.dbg %unbox_zero : i64
    // CHECK: 0

    // -1 (all bits set)
    %neg_one = arith.constant -1 : i64
    %box_neg1 = eco.box %neg_one : i64 -> !eco.value
    %unbox_neg1 = eco.unbox %box_neg1 : !eco.value -> i64
    eco.dbg %unbox_neg1 : i64
    // CHECK: -1

    // Float +Inf
    %one = arith.constant 1.0 : f64
    %zero_f = arith.constant 0.0 : f64
    %inf = arith.divf %one, %zero_f : f64
    %box_inf = eco.box %inf : f64 -> !eco.value
    %unbox_inf = eco.unbox %box_inf : !eco.value -> f64
    // Check it's still infinity
    %million = arith.constant 1000000.0 : f64
    %is_huge = eco.float.gt %unbox_inf, %million : f64
    %is_huge_ext = arith.extui %is_huge : i1 to i64
    eco.dbg %is_huge_ext : i64
    // CHECK: 1

    // Float -Inf
    %neg_inf = arith.negf %inf : f64
    %box_neg_inf = eco.box %neg_inf : f64 -> !eco.value
    %unbox_neg_inf = eco.unbox %box_neg_inf : !eco.value -> f64
    %neg_million = arith.constant -1000000.0 : f64
    %is_neg_huge = eco.float.lt %unbox_neg_inf, %neg_million : f64
    %is_neg_huge_ext = arith.extui %is_neg_huge : i1 to i64
    eco.dbg %is_neg_huge_ext : i64
    // CHECK: 1

    // Float +0.0
    %pos_zero = arith.constant 0.0 : f64
    %box_pos_zero = eco.box %pos_zero : f64 -> !eco.value
    %unbox_pos_zero = eco.unbox %box_pos_zero : !eco.value -> f64
    eco.dbg %unbox_pos_zero : f64
    // CHECK: 0

    // Float -0.0
    %neg_zero = arith.constant -0.0 : f64
    %box_neg_zero = eco.box %neg_zero : f64 -> !eco.value
    %unbox_neg_zero = eco.unbox %box_neg_zero : !eco.value -> f64
    // Test by dividing: 1/-0 = -Inf
    %div_neg_zero = arith.divf %one, %unbox_neg_zero : f64
    %is_neg_inf = eco.float.lt %div_neg_zero, %neg_million : f64
    %is_neg_inf_ext = arith.extui %is_neg_inf : i1 to i64
    eco.dbg %is_neg_inf_ext : i64
    // CHECK: 1

    // Unicode char (max BMP: U+FFFF)
    %max_bmp = arith.constant 65535 : i32
    %box_char = eco.box %max_bmp : i32 -> !eco.value
    %unbox_char = eco.unbox %box_char : !eco.value -> i32
    %char_ok = arith.cmpi eq, %unbox_char, %max_bmp : i32
    %char_ok_ext = arith.extui %char_ok : i1 to i64
    eco.dbg %char_ok_ext : i64
    // CHECK: 1

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
