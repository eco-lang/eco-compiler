// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test loop decode with single item

module {
  func.func @main() -> i64 {
    // Create buffer: count (4 bytes) + one u8 item
    %size = arith.constant 8 : i32
    %buffer = bf.alloc %size : i64
    %cursor0 = bf.cursor.init %buffer : i64 -> !bf.cursor

    // Write count = 1
    %count = arith.constant 1 : i64
    %cursor1 = bf.write.u32 %cursor0, %count (le) : !bf.cursor

    // Write single item
    %item = arith.constant 42 : i64
    %cursor2 = bf.write.u8 %cursor1, %item : !bf.cursor

    // Read count and item
    %rc0 = bf.decoder.cursor.init %buffer : i64 -> !bf.cursor
    %read_count, %rc1 = bf.read.u32 %rc0 (le) : i64, !bf.cursor
    %read_item, %rc2 = bf.read.u8 %rc1 : i64, !bf.cursor

    eco.dbg %read_count : i64
    // CHECK: 1
    eco.dbg %read_item : i64
    // CHECK: 42

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
