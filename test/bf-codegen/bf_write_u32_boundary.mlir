// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test bf.write.u32 edge cases: 0, max_i32 (2147483647), max_u32 (4294967295)

module {
  func.func @main() -> i64 {
    // Allocate buffer for 12 bytes (3 x u32)
    %size = arith.constant 12 : i32
    %buffer = bf.alloc %size : i64
    %cursor0 = bf.cursor.init %buffer : !bf.cursor

    // Write boundary values (little-endian)
    %val0 = arith.constant 0 : i64
    %cursor1 = bf.write.u32 %cursor0, %val0 (le) : !bf.cursor

    %val_max_i32 = arith.constant 2147483647 : i64
    %cursor2 = bf.write.u32 %cursor1, %val_max_i32 (le) : !bf.cursor

    %val_max_u32 = arith.constant 4294967295 : i64
    %cursor3 = bf.write.u32 %cursor2, %val_max_u32 (le) : !bf.cursor

    // Read back all values
    %read_cursor0 = bf.decoder.cursor.init %buffer : !bf.cursor
    %r0, %read_cursor1 = bf.read.u32 %read_cursor0 (le) : i64, !bf.cursor
    %r1, %read_cursor2 = bf.read.u32 %read_cursor1 (le) : i64, !bf.cursor
    %r2, %read_cursor3 = bf.read.u32 %read_cursor2 (le) : i64, !bf.cursor

    eco.dbg %r0 : i64
    // CHECK: 0
    eco.dbg %r1 : i64
    // CHECK: 2147483647
    eco.dbg %r2 : i64
    // CHECK: 4294967295

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
