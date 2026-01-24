// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test u32 BE vs LE byte order

module {
  func.func @main() -> i64 {
    %val = arith.constant 0x12345678 : i64

    // Write as big-endian
    %size = arith.constant 8 : i32
    %be_buf = bf.alloc %size : i64
    %be_c0 = bf.cursor.init %be_buf : !bf.cursor
    %be_c1 = bf.write.u32 %be_c0, %val (be) : !bf.cursor

    // Write as little-endian
    %le_buf = bf.alloc %size : i64
    %le_c0 = bf.cursor.init %le_buf : !bf.cursor
    %le_c1 = bf.write.u32 %le_c0, %val (le) : !bf.cursor

    // Read first byte of each
    %be_rc0 = bf.decoder.cursor.init %be_buf : !bf.cursor
    %be_b1, %be_rc1 = bf.read.u8 %be_rc0 : i64, !bf.cursor

    %le_rc0 = bf.decoder.cursor.init %le_buf : !bf.cursor
    %le_b1, %le_rc1 = bf.read.u8 %le_rc0 : i64, !bf.cursor

    // BE: first byte is 0x12 (18)
    eco.dbg %be_b1 : i64
    // CHECK: 18

    // LE: first byte is 0x78 (120)
    eco.dbg %le_b1 : i64
    // CHECK: 120

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
