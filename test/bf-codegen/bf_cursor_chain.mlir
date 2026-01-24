// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test cursor threading through multiple writes

module {
  func.func @main() -> i64 {
    // Allocate buffer
    %size = arith.constant 16 : i32
    %buffer = bf.alloc %size : i64
    %c0 = bf.cursor.init %buffer : !bf.cursor

    // Chain of writes - each uses result of previous
    %v1 = arith.constant 1 : i64
    %c1 = bf.write.u8 %c0, %v1 : !bf.cursor
    %v2 = arith.constant 2 : i64
    %c2 = bf.write.u8 %c1, %v2 : !bf.cursor
    %v3 = arith.constant 3 : i64
    %c3 = bf.write.u8 %c2, %v3 : !bf.cursor
    %v4 = arith.constant 4 : i64
    %c4 = bf.write.u8 %c3, %v4 : !bf.cursor
    %v5 = arith.constant 5 : i64
    %c5 = bf.write.u8 %c4, %v5 : !bf.cursor

    // Read back to verify correct cursor threading
    %read_cursor0 = bf.decoder.cursor.init %buffer : !bf.cursor
    %r1, %read_cursor1 = bf.read.u8 %read_cursor0 : i64, !bf.cursor
    %r2, %read_cursor2 = bf.read.u8 %read_cursor1 : i64, !bf.cursor
    %r3, %read_cursor3 = bf.read.u8 %read_cursor2 : i64, !bf.cursor
    %r4, %read_cursor4 = bf.read.u8 %read_cursor3 : i64, !bf.cursor
    %r5, %read_cursor5 = bf.read.u8 %read_cursor4 : i64, !bf.cursor

    eco.dbg %r1 : i64
    // CHECK: 1
    eco.dbg %r2 : i64
    // CHECK: 2
    eco.dbg %r3 : i64
    // CHECK: 3
    eco.dbg %r4 : i64
    // CHECK: 4
    eco.dbg %r5 : i64
    // CHECK: 5

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
