// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test decode then encode: start from known bytes

module {
  func.func @main() -> i64 {
    // Create buffer with known bytes
    %size = arith.constant 4 : i32
    %buffer = bf.alloc %size : i64
    %cursor0 = bf.cursor.init %buffer : !bf.cursor

    // Write original bytes: 0xAA, 0xBB, 0xCC
    %b1 = arith.constant 170 : i64  // 0xAA
    %cursor1 = bf.write.u8 %cursor0, %b1 : !bf.cursor
    %b2 = arith.constant 187 : i64  // 0xBB
    %cursor2 = bf.write.u8 %cursor1, %b2 : !bf.cursor
    %b3 = arith.constant 204 : i64  // 0xCC
    %cursor3 = bf.write.u8 %cursor2, %b3 : !bf.cursor

    // Decode
    %read_cursor0 = bf.decoder.cursor.init %buffer : !bf.cursor
    %v1, %read_cursor1 = bf.read.u8 %read_cursor0 : i64, !bf.cursor
    %v2, %read_cursor2 = bf.read.u8 %read_cursor1 : i64, !bf.cursor
    %v3, %read_cursor3 = bf.read.u8 %read_cursor2 : i64, !bf.cursor

    // Encode to new buffer
    %new_size = arith.constant 4 : i32
    %new_buffer = bf.alloc %new_size : i64
    %new_cursor0 = bf.cursor.init %new_buffer : !bf.cursor
    %new_cursor1 = bf.write.u8 %new_cursor0, %v1 : !bf.cursor
    %new_cursor2 = bf.write.u8 %new_cursor1, %v2 : !bf.cursor
    %new_cursor3 = bf.write.u8 %new_cursor2, %v3 : !bf.cursor

    // Verify by reading back
    %verify_cursor0 = bf.decoder.cursor.init %new_buffer : !bf.cursor
    %r1, %verify_cursor1 = bf.read.u8 %verify_cursor0 : i64, !bf.cursor
    %r2, %verify_cursor2 = bf.read.u8 %verify_cursor1 : i64, !bf.cursor
    %r3, %verify_cursor3 = bf.read.u8 %verify_cursor2 : i64, !bf.cursor

    eco.dbg %r1 : i64
    // CHECK: 170
    eco.dbg %r2 : i64
    // CHECK: 187
    eco.dbg %r3 : i64
    // CHECK: 204

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
