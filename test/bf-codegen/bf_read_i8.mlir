// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test bf.read.i8 - read signed 8-bit value

module {
  func.func @main() -> i64 {
    // Create buffer with signed values
    %size = arith.constant 4 : i32
    %buffer = bf.alloc %size : i64
    %cursor0 = bf.cursor.init %buffer : !bf.cursor

    // Write: 50 (positive), 127 (max positive)
    %v50 = arith.constant 50 : i64
    %cursor1 = bf.write.u8 %cursor0, %v50 : !bf.cursor
    %v127 = arith.constant 127 : i64
    %cursor2 = bf.write.u8 %cursor1, %v127 : !bf.cursor

    // Read back as signed
    %read_cursor0 = bf.decoder.cursor.init %buffer : !bf.cursor
    %r0, %read_cursor1 = bf.read.i8 %read_cursor0 : i64, !bf.cursor
    %r1, %read_cursor2 = bf.read.i8 %read_cursor1 : i64, !bf.cursor

    eco.dbg %r0 : i64
    // CHECK: 50
    eco.dbg %r1 : i64
    // CHECK: 127

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
