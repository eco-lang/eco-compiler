// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test bf.read.u32 with little-endian

module {
  func.func @main() -> i64 {
    // Create buffer
    %size = arith.constant 8 : i32
    %buffer = bf.alloc %size : i64
    %cursor0 = bf.cursor.init %buffer : !bf.cursor

    // Write u32 little-endian (0xCAFEBABE = 3405691582)
    %val = arith.constant 3405691582 : i64
    %cursor1 = bf.write.u32 %cursor0, %val (le) : !bf.cursor

    // Read back
    %read_cursor0 = bf.decoder.cursor.init %buffer : !bf.cursor
    %read_val, %read_cursor1 = bf.read.u32 %read_cursor0 (le) : i64, !bf.cursor

    eco.dbg %read_val : i64
    // CHECK: 3405691582

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
