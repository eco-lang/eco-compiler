// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test bf.write.u16 edge cases: 0, 32767, 65535

module {
  func.func @main() -> i64 {
    // Allocate buffer for 6 bytes (3 x u16)
    %size = arith.constant 6 : i32
    %buffer = bf.alloc %size : i64
    %cursor0 = bf.cursor.init %buffer : !bf.cursor

    // Write boundary values (little-endian)
    %val0 = arith.constant 0 : i64
    %cursor1 = bf.write.u16 %cursor0, %val0 (le) : !bf.cursor

    %val32767 = arith.constant 32767 : i64
    %cursor2 = bf.write.u16 %cursor1, %val32767 (le) : !bf.cursor

    %val65535 = arith.constant 65535 : i64
    %cursor3 = bf.write.u16 %cursor2, %val65535 (le) : !bf.cursor

    // Read back all values
    %read_cursor0 = bf.decoder.cursor.init %buffer : !bf.cursor
    %r0, %read_cursor1 = bf.read.u16 %read_cursor0 (le) : i64, !bf.cursor
    %r1, %read_cursor2 = bf.read.u16 %read_cursor1 (le) : i64, !bf.cursor
    %r2, %read_cursor3 = bf.read.u16 %read_cursor2 (le) : i64, !bf.cursor

    eco.dbg %r0 : i64
    // CHECK: 0
    eco.dbg %r1 : i64
    // CHECK: 32767
    eco.dbg %r2 : i64
    // CHECK: 65535

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
