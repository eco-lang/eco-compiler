// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test bf.read.i16 signed little-endian

module {
  func.func @main() -> i64 {
    // Create buffer
    %size = arith.constant 8 : i32
    %buffer = bf.alloc %size : i64
    %cursor0 = bf.cursor.init %buffer : i64 -> !bf.cursor

    // Write positive and negative values
    %pos = arith.constant 1000 : i64
    %cursor1 = bf.write.u16 %cursor0, %pos (le) : !bf.cursor
    %neg = arith.constant 65535 : i64  // -1 as i16
    %cursor2 = bf.write.u16 %cursor1, %neg (le) : !bf.cursor

    // Read back
    %read_cursor0 = bf.decoder.cursor.init %buffer : i64 -> !bf.cursor
    %r0, %read_cursor1 = bf.read.i16 %read_cursor0 (le) : i64, !bf.cursor
    %r1, %read_cursor2 = bf.read.i16 %read_cursor1 (le) : i64, !bf.cursor

    eco.dbg %r0 : i64
    // CHECK: 1000
    eco.dbg %r1 : i64
    // CHECK: -1

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
