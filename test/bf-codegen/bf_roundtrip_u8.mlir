// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test roundtrip: write u8, read back, verify match

module {
  func.func @main() -> i64 {
    // Test values
    %val1 = arith.constant 0 : i64
    %val2 = arith.constant 127 : i64
    %val3 = arith.constant 255 : i64

    // Create buffer and write
    %size = arith.constant 4 : i32
    %buffer = bf.alloc %size : i64
    %cursor0 = bf.cursor.init %buffer : !bf.cursor
    %cursor1 = bf.write.u8 %cursor0, %val1 : !bf.cursor
    %cursor2 = bf.write.u8 %cursor1, %val2 : !bf.cursor
    %cursor3 = bf.write.u8 %cursor2, %val3 : !bf.cursor

    // Read back
    %read_cursor0 = bf.decoder.cursor.init %buffer : !bf.cursor
    %r1, %read_cursor1 = bf.read.u8 %read_cursor0 : i64, !bf.cursor
    %r2, %read_cursor2 = bf.read.u8 %read_cursor1 : i64, !bf.cursor
    %r3, %read_cursor3 = bf.read.u8 %read_cursor2 : i64, !bf.cursor

    // Verify match
    %match1 = arith.cmpi eq, %val1, %r1 : i64
    %match2 = arith.cmpi eq, %val2, %r2 : i64
    %match3 = arith.cmpi eq, %val3, %r3 : i64
    %all_match = arith.andi %match1, %match2 : i1
    %all_match2 = arith.andi %all_match, %match3 : i1
    %result = arith.extui %all_match2 : i1 to i64
    eco.dbg %result : i64
    // CHECK: 1

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
