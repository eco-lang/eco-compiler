// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test loop decode with count=0 (empty list)

module {
  func.func @main() -> i64 {
    // Create buffer with count=0
    %size = arith.constant 4 : i32
    %buffer = bf.alloc %size : i64
    %cursor0 = bf.cursor.init %buffer : !bf.cursor

    // Write count = 0
    %count = arith.constant 0 : i64
    %cursor1 = bf.write.u32 %cursor0, %count (le) : !bf.cursor

    // Read count
    %rc0 = bf.decoder.cursor.init %buffer : !bf.cursor
    %read_count, %rc1 = bf.read.u32 %rc0 (le) : i64, !bf.cursor

    eco.dbg %read_count : i64
    // CHECK: 0

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
