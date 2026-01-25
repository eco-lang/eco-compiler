// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test interleaved cursor operations with different sizes

module {
  func.func @main() -> i64 {
    // Create buffer for mixed types
    %size = arith.constant 32 : i32
    %buffer = bf.alloc %size : i64
    %c0 = bf.cursor.init %buffer : i64 -> !bf.cursor

    // Write: u8, u32, u8, u16, f64
    %v_u8_1 = arith.constant 0xAA : i64
    %c1 = bf.write.u8 %c0, %v_u8_1 : !bf.cursor

    %v_u32 = arith.constant 0x12345678 : i64
    %c2 = bf.write.u32 %c1, %v_u32 (le) : !bf.cursor

    %v_u8_2 = arith.constant 0xBB : i64
    %c3 = bf.write.u8 %c2, %v_u8_2 : !bf.cursor

    %v_u16 = arith.constant 0xCCDD : i64
    %c4 = bf.write.u16 %c3, %v_u16 (be) : !bf.cursor

    %v_f64 = arith.constant 3.14 : f64
    %c5 = bf.write.f64 %c4, %v_f64 (le) : !bf.cursor

    // Read back with correct threading
    %rc0 = bf.decoder.cursor.init %buffer : i64 -> !bf.cursor
    %r_u8_1, %rc1 = bf.read.u8 %rc0 : i64, !bf.cursor
    %r_u32, %rc2 = bf.read.u32 %rc1 (le) : i64, !bf.cursor
    %r_u8_2, %rc3 = bf.read.u8 %rc2 : i64, !bf.cursor
    %r_u16, %rc4 = bf.read.u16 %rc3 (be) : i64, !bf.cursor
    %r_f64, %rc5 = bf.read.f64 %rc4 (le) : f64, !bf.cursor

    eco.dbg %r_u8_1 : i64
    // CHECK: 170
    eco.dbg %r_u32 : i64
    // CHECK: 305419896
    eco.dbg %r_u8_2 : i64
    // CHECK: 187
    eco.dbg %r_u16 : i64
    // CHECK: 52445
    eco.dbg %r_f64 : f64
    // CHECK: 3.14

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
