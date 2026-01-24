// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test decode u32 BE then encode, compare bytes

module {
  func.func @main() -> i64 {
    // Create buffer with u32 BE value
    %size = arith.constant 8 : i32
    %buffer = bf.alloc %size : i64
    %cursor0 = bf.cursor.init %buffer : !bf.cursor

    %orig = arith.constant 0x12345678 : i64
    %cursor1 = bf.write.u32 %cursor0, %orig (be) : !bf.cursor

    // Decode
    %read_cursor0 = bf.decoder.cursor.init %buffer : !bf.cursor
    %val, %read_cursor1 = bf.read.u32 %read_cursor0 (be) : i64, !bf.cursor

    // Re-encode to new buffer
    %new_buffer = bf.alloc %size : i64
    %new_cursor0 = bf.cursor.init %new_buffer : !bf.cursor
    %new_cursor1 = bf.write.u32 %new_cursor0, %val (be) : !bf.cursor

    // Verify by comparing individual bytes
    %orig_read0 = bf.decoder.cursor.init %buffer : !bf.cursor
    %new_read0 = bf.decoder.cursor.init %new_buffer : !bf.cursor

    %ob1, %orig_read1 = bf.read.u8 %orig_read0 : i64, !bf.cursor
    %nb1, %new_read1 = bf.read.u8 %new_read0 : i64, !bf.cursor
    %m1 = arith.cmpi eq, %ob1, %nb1 : i64

    %ob2, %orig_read2 = bf.read.u8 %orig_read1 : i64, !bf.cursor
    %nb2, %new_read2 = bf.read.u8 %new_read1 : i64, !bf.cursor
    %m2 = arith.cmpi eq, %ob2, %nb2 : i64

    %ob3, %orig_read3 = bf.read.u8 %orig_read2 : i64, !bf.cursor
    %nb3, %new_read3 = bf.read.u8 %new_read2 : i64, !bf.cursor
    %m3 = arith.cmpi eq, %ob3, %nb3 : i64

    %ob4, %orig_read4 = bf.read.u8 %orig_read3 : i64, !bf.cursor
    %nb4, %new_read4 = bf.read.u8 %new_read3 : i64, !bf.cursor
    %m4 = arith.cmpi eq, %ob4, %nb4 : i64

    %all = arith.andi %m1, %m2 : i1
    %all2 = arith.andi %all, %m3 : i1
    %all3 = arith.andi %all2, %m4 : i1
    %result = arith.extui %all3 : i1 to i64
    eco.dbg %result : i64
    // CHECK: 1

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
