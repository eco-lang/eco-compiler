// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test eco.int.pow edge cases: 0^0, x^0, 0^n, 1^n.

module {
  func.func @main() -> i64 {
    %zero = arith.constant 0 : i64
    %one = arith.constant 1 : i64
    %two = arith.constant 2 : i64
    %three = arith.constant 3 : i64
    %ten = arith.constant 10 : i64
    %hundred = arith.constant 100 : i64

    // 0^0 = 1 (mathematical convention)
    %pow_0_0 = eco.int.pow %zero, %zero : i64
    eco.dbg %pow_0_0 : i64
    // CHECK: 1

    // x^0 = 1 for any x
    %pow_2_0 = eco.int.pow %two, %zero : i64
    eco.dbg %pow_2_0 : i64
    // CHECK: 1

    %pow_100_0 = eco.int.pow %hundred, %zero : i64
    eco.dbg %pow_100_0 : i64
    // CHECK: 1

    // 0^n = 0 for n > 0
    %pow_0_1 = eco.int.pow %zero, %one : i64
    eco.dbg %pow_0_1 : i64
    // CHECK: 0

    %pow_0_10 = eco.int.pow %zero, %ten : i64
    eco.dbg %pow_0_10 : i64
    // CHECK: 0

    // 1^n = 1 for any n
    %pow_1_0 = eco.int.pow %one, %zero : i64
    eco.dbg %pow_1_0 : i64
    // CHECK: 1

    %pow_1_10 = eco.int.pow %one, %ten : i64
    eco.dbg %pow_1_10 : i64
    // CHECK: 1

    %pow_1_100 = eco.int.pow %one, %hundred : i64
    eco.dbg %pow_1_100 : i64
    // CHECK: 1

    // Normal powers
    // 2^10 = 1024
    %pow_2_10 = eco.int.pow %two, %ten : i64
    eco.dbg %pow_2_10 : i64
    // CHECK: 1024

    // 3^3 = 27
    %pow_3_3 = eco.int.pow %three, %three : i64
    eco.dbg %pow_3_3 : i64
    // CHECK: 27

    // 10^2 = 100
    %pow_10_2 = eco.int.pow %ten, %two : i64
    eco.dbg %pow_10_2 : i64
    // CHECK: 100

    // Negative exponent returns 0 (integer division result)
    %neg_one = arith.constant -1 : i64
    %pow_2_neg1 = eco.int.pow %two, %neg_one : i64
    eco.dbg %pow_2_neg1 : i64
    // CHECK: 0

    return %zero : i64
  }
}
