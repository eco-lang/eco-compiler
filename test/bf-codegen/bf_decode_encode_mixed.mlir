// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test decode mixed sequence then encode, compare

module {
  func.func @main() -> i64 {
    // Create buffer with u8 + u16 + u32
    %size = arith.constant 8 : i32
    %buffer = bf.alloc %size : i64
    %cursor0 = bf.cursor.init %buffer : i64 -> !bf.cursor

    %v_u8 = arith.constant 99 : i64
    %cursor1 = bf.write.u8 %cursor0, %v_u8 : !bf.cursor
    %v_u16 = arith.constant 0x1234 : i64
    %cursor2 = bf.write.u16 %cursor1, %v_u16 (le) : !bf.cursor
    %v_u32 = arith.constant 0xDEADBEEF : i64
    %cursor3 = bf.write.u32 %cursor2, %v_u32 (be) : !bf.cursor

    // Decode sequence
    %read_cursor0 = bf.decoder.cursor.init %buffer : i64 -> !bf.cursor
    %d_u8, %read_cursor1 = bf.read.u8 %read_cursor0 : i64, !bf.cursor
    %d_u16, %read_cursor2 = bf.read.u16 %read_cursor1 (le) : i64, !bf.cursor
    %d_u32, %read_cursor3 = bf.read.u32 %read_cursor2 (be) : i64, !bf.cursor

    // Re-encode to new buffer
    %new_buffer = bf.alloc %size : i64
    %new_cursor0 = bf.cursor.init %new_buffer : i64 -> !bf.cursor
    %new_cursor1 = bf.write.u8 %new_cursor0, %d_u8 : !bf.cursor
    %new_cursor2 = bf.write.u16 %new_cursor1, %d_u16 (le) : !bf.cursor
    %new_cursor3 = bf.write.u32 %new_cursor2, %d_u32 (be) : !bf.cursor

    // Verify by reading back
    %verify_cursor0 = bf.decoder.cursor.init %new_buffer : i64 -> !bf.cursor
    %r_u8, %verify_cursor1 = bf.read.u8 %verify_cursor0 : i64, !bf.cursor
    %r_u16, %verify_cursor2 = bf.read.u16 %verify_cursor1 (le) : i64, !bf.cursor
    %r_u32, %verify_cursor3 = bf.read.u32 %verify_cursor2 (be) : i64, !bf.cursor

    %m1 = arith.cmpi eq, %v_u8, %r_u8 : i64
    %m2 = arith.cmpi eq, %v_u16, %r_u16 : i64
    %m3 = arith.cmpi eq, %v_u32, %r_u32 : i64
    %all = arith.andi %m1, %m2 : i1
    %all2 = arith.andi %all, %m3 : i1
    %result = arith.extui %all2 : i1 to i64
    eco.dbg %result : i64
    // CHECK: 1

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
