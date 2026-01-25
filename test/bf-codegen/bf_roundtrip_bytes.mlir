// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test roundtrip: write bytes, read back, verify

module {
  func.func @main() -> i64 {
    // Create source buffer with 4 bytes
    %src_size = arith.constant 4 : i32
    %src = bf.alloc %src_size : i64
    %src_cursor0 = bf.cursor.init %src : i64 -> !bf.cursor

    // Write known pattern
    %v1 = arith.constant 0x11 : i64
    %src_cursor1 = bf.write.u8 %src_cursor0, %v1 : !bf.cursor
    %v2 = arith.constant 0x22 : i64
    %src_cursor2 = bf.write.u8 %src_cursor1, %v2 : !bf.cursor
    %v3 = arith.constant 0x33 : i64
    %src_cursor3 = bf.write.u8 %src_cursor2, %v3 : !bf.cursor
    %v4 = arith.constant 0x44 : i64
    %src_cursor4 = bf.write.u8 %src_cursor3, %v4 : !bf.cursor

    // Create destination and copy
    %dst_size = arith.constant 8 : i32
    %dst = bf.alloc %dst_size : i64
    %dst_cursor0 = bf.cursor.init %dst : i64 -> !bf.cursor
    %dst_cursor1 = bf.write.bytes %dst_cursor0, %src : (i64) -> !bf.cursor

    // Read back from destination as bytes
    %read_cursor0 = bf.decoder.cursor.init %dst : i64 -> !bf.cursor
    %len = arith.constant 4 : i32
    %bytes, %read_cursor1, %ok = bf.read.bytes %read_cursor0, %len : i64, !bf.cursor, i1

    // Verify by reading first byte of result
    %bytes_cursor = bf.decoder.cursor.init %bytes : i64 -> !bf.cursor
    %r1, %bytes_cursor1 = bf.read.u8 %bytes_cursor : i64, !bf.cursor

    eco.dbg %r1 : i64
    // CHECK: 17

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
