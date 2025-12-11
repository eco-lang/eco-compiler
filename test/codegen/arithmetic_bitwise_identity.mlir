// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test bitwise operation identities.

module {
  func.func @main() -> i64 {
    %x = arith.constant 12345 : i64
    %y = arith.constant 67890 : i64
    %c0 = arith.constant 0 : i64
    %all_ones = arith.constant -1 : i64

    // x AND 0 = 0
    %and_0 = eco.int.and %x, %c0 : i64
    eco.dbg %and_0 : i64
    // CHECK: 0

    // x AND -1 = x
    %and_1 = eco.int.and %x, %all_ones : i64
    eco.dbg %and_1 : i64
    // CHECK: 12345

    // x AND x = x
    %and_self = eco.int.and %x, %x : i64
    eco.dbg %and_self : i64
    // CHECK: 12345

    // x OR 0 = x
    %or_0 = eco.int.or %x, %c0 : i64
    eco.dbg %or_0 : i64
    // CHECK: 12345

    // x OR -1 = -1
    %or_1 = eco.int.or %x, %all_ones : i64
    eco.dbg %or_1 : i64
    // CHECK: -1

    // x OR x = x
    %or_self = eco.int.or %x, %x : i64
    eco.dbg %or_self : i64
    // CHECK: 12345

    // x XOR 0 = x
    %xor_0 = eco.int.xor %x, %c0 : i64
    eco.dbg %xor_0 : i64
    // CHECK: 12345

    // x XOR x = 0
    %xor_self = eco.int.xor %x, %x : i64
    eco.dbg %xor_self : i64
    // CHECK: 0

    // x XOR -1 = complement(x)
    %xor_1 = eco.int.xor %x, %all_ones : i64
    %comp_x = eco.int.complement %x : i64
    eco.dbg %xor_1 : i64
    eco.dbg %comp_x : i64
    // CHECK: -12346
    // CHECK: -12346

    // complement(complement(x)) = x
    %comp_comp = eco.int.complement %comp_x : i64
    eco.dbg %comp_comp : i64
    // CHECK: 12345

    // complement(0) = -1
    %comp_0 = eco.int.complement %c0 : i64
    eco.dbg %comp_0 : i64
    // CHECK: -1

    // complement(-1) = 0
    %comp_neg1 = eco.int.complement %all_ones : i64
    eco.dbg %comp_neg1 : i64
    // CHECK: 0

    // Commutativity: x AND y = y AND x
    %and_xy = eco.int.and %x, %y : i64
    %and_yx = eco.int.and %y, %x : i64
    eco.dbg %and_xy : i64
    eco.dbg %and_yx : i64
    // CHECK: 48
    // CHECK: 48

    // Commutativity: x OR y = y OR x
    %or_xy = eco.int.or %x, %y : i64
    %or_yx = eco.int.or %y, %x : i64
    eco.dbg %or_xy : i64
    eco.dbg %or_yx : i64
    // CHECK: 80187
    // CHECK: 80187

    // Commutativity: x XOR y = y XOR x
    %xor_xy = eco.int.xor %x, %y : i64
    %xor_yx = eco.int.xor %y, %x : i64
    eco.dbg %xor_xy : i64
    eco.dbg %xor_yx : i64
    // CHECK: 80139
    // CHECK: 80139

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
