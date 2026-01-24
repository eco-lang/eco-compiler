// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test loop decode that would exceed bounds

module {
  func.func @main() -> i64 {
    // Create buffer with count claiming more items than exist
    %size = arith.constant 8 : i32
    %buffer = bf.alloc %size : i64
    %cursor0 = bf.cursor.init %buffer : !bf.cursor

    // Write count = 10 (but only provide 2 items)
    %count = arith.constant 10 : i64
    %cursor1 = bf.write.u32 %cursor0, %count (le) : !bf.cursor

    // Write only 2 items
    %v1 = arith.constant 1 : i64
    %cursor2 = bf.write.u8 %cursor1, %v1 : !bf.cursor
    %v2 = arith.constant 2 : i64
    %cursor3 = bf.write.u8 %cursor2, %v2 : !bf.cursor

    // Check bounds after reading count
    %rc0 = bf.decoder.cursor.init %buffer : !bf.cursor
    %read_count, %rc1 = bf.read.u32 %rc0 (le) : i64, !bf.cursor

    // Check if we have enough bytes for 10 items
    %needed = arith.constant 10 : i32  // 10 u8 items
    %ok = bf.require %rc1, %needed : i1
    %ok_int = arith.extui %ok : i1 to i64
    eco.dbg %ok_int : i64
    // CHECK: 0

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
