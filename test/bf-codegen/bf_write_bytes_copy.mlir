// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test bf.write.bytes - copy ByteBuffer payload

module {
  func.func @main() -> i64 {
    // Create source ByteBuffer with 4 bytes
    %src_size = arith.constant 4 : i32
    %src_buffer = bf.alloc %src_size : i64
    %src_cursor0 = bf.cursor.init %src_buffer : !bf.cursor

    // Fill source with known values
    %v1 = arith.constant 0x11 : i64
    %src_cursor1 = bf.write.u8 %src_cursor0, %v1 : !bf.cursor
    %v2 = arith.constant 0x22 : i64
    %src_cursor2 = bf.write.u8 %src_cursor1, %v2 : !bf.cursor
    %v3 = arith.constant 0x33 : i64
    %src_cursor3 = bf.write.u8 %src_cursor2, %v3 : !bf.cursor
    %v4 = arith.constant 0x44 : i64
    %src_cursor4 = bf.write.u8 %src_cursor3, %v4 : !bf.cursor

    // Create destination buffer and copy bytes
    %dst_size = arith.constant 8 : i32
    %dst_buffer = bf.alloc %dst_size : i64
    %dst_cursor0 = bf.cursor.init %dst_buffer : !bf.cursor

    %dst_cursor1 = bf.write.bytes %dst_cursor0, %src_buffer : !bf.cursor

    // Read back from destination
    %read_cursor0 = bf.decoder.cursor.init %dst_buffer : !bf.cursor
    %r1, %read_cursor1 = bf.read.u8 %read_cursor0 : i64, !bf.cursor
    %r2, %read_cursor2 = bf.read.u8 %read_cursor1 : i64, !bf.cursor
    %r3, %read_cursor3 = bf.read.u8 %read_cursor2 : i64, !bf.cursor
    %r4, %read_cursor4 = bf.read.u8 %read_cursor3 : i64, !bf.cursor

    eco.dbg %r1 : i64
    // CHECK: 17
    eco.dbg %r2 : i64
    // CHECK: 34
    eco.dbg %r3 : i64
    // CHECK: 51
    eco.dbg %r4 : i64
    // CHECK: 68

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
