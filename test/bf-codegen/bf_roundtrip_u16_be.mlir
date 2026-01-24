// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test roundtrip: write u16 BE, read back, verify match

module {
  func.func @main() -> i64 {
    %val = arith.constant 0xABCD : i64

    // Create buffer and write
    %size = arith.constant 4 : i32
    %buffer = bf.alloc %size : i64
    %cursor0 = bf.cursor.init %buffer : !bf.cursor
    %cursor1 = bf.write.u16 %cursor0, %val (be) : !bf.cursor

    // Read back
    %read_cursor0 = bf.decoder.cursor.init %buffer : !bf.cursor
    %result, %read_cursor1 = bf.read.u16 %read_cursor0 (be) : i64, !bf.cursor

    // Verify match
    %match = arith.cmpi eq, %val, %result : i64
    %match_int = arith.extui %match : i1 to i64
    eco.dbg %match_int : i64
    // CHECK: 1

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
