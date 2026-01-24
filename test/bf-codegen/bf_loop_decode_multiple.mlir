// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test loop decode with multiple items

module {
  func.func @main() -> i64 {
    // Create buffer: count (4 bytes) + 5 u8 items
    %size = arith.constant 16 : i32
    %buffer = bf.alloc %size : i64
    %cursor0 = bf.cursor.init %buffer : !bf.cursor

    // Write count = 5
    %count = arith.constant 5 : i64
    %cursor1 = bf.write.u32 %cursor0, %count (le) : !bf.cursor

    // Write 5 items: 10, 20, 30, 40, 50
    %v1 = arith.constant 10 : i64
    %cursor2 = bf.write.u8 %cursor1, %v1 : !bf.cursor
    %v2 = arith.constant 20 : i64
    %cursor3 = bf.write.u8 %cursor2, %v2 : !bf.cursor
    %v3 = arith.constant 30 : i64
    %cursor4 = bf.write.u8 %cursor3, %v3 : !bf.cursor
    %v4 = arith.constant 40 : i64
    %cursor5 = bf.write.u8 %cursor4, %v4 : !bf.cursor
    %v5 = arith.constant 50 : i64
    %cursor6 = bf.write.u8 %cursor5, %v5 : !bf.cursor

    // Read count and items
    %rc0 = bf.decoder.cursor.init %buffer : !bf.cursor
    %read_count, %rc1 = bf.read.u32 %rc0 (le) : i64, !bf.cursor
    %r1, %rc2 = bf.read.u8 %rc1 : i64, !bf.cursor
    %r2, %rc3 = bf.read.u8 %rc2 : i64, !bf.cursor
    %r3, %rc4 = bf.read.u8 %rc3 : i64, !bf.cursor
    %r4, %rc5 = bf.read.u8 %rc4 : i64, !bf.cursor
    %r5, %rc6 = bf.read.u8 %rc5 : i64, !bf.cursor

    eco.dbg %read_count : i64
    // CHECK: 5

    // Sum all items
    %sum1 = arith.addi %r1, %r2 : i64
    %sum2 = arith.addi %sum1, %r3 : i64
    %sum3 = arith.addi %sum2, %r4 : i64
    %sum4 = arith.addi %sum3, %r5 : i64
    eco.dbg %sum4 : i64
    // CHECK: 150

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
