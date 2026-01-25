// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test count-prefixed list roundtrip:
// [count: u32] [items: count x u16]

module {
  func.func @main() -> i64 {
    // Allocate buffer for: u32 count + 3 x u16
    %size = arith.constant 16 : i32
    %buffer = bf.alloc %size : i64
    %c0 = bf.cursor.init %buffer : i64 -> !bf.cursor

    // Write count = 3
    %count = arith.constant 3 : i64
    %c1 = bf.write.u32 %c0, %count (le) : !bf.cursor

    // Write 3 items: 100, 200, 300
    %v1 = arith.constant 100 : i64
    %c2 = bf.write.u16 %c1, %v1 (le) : !bf.cursor
    %v2 = arith.constant 200 : i64
    %c3 = bf.write.u16 %c2, %v2 (le) : !bf.cursor
    %v3 = arith.constant 300 : i64
    %c4 = bf.write.u16 %c3, %v3 (le) : !bf.cursor

    // Decode: read count then items
    %rc0 = bf.decoder.cursor.init %buffer : i64 -> !bf.cursor
    %read_count, %rc1 = bf.read.u32 %rc0 (le) : i64, !bf.cursor

    eco.dbg %read_count : i64
    // CHECK: 3

    // Read 3 items
    %r1, %rc2 = bf.read.u16 %rc1 (le) : i64, !bf.cursor
    %r2, %rc3 = bf.read.u16 %rc2 (le) : i64, !bf.cursor
    %r3, %rc4 = bf.read.u16 %rc3 (le) : i64, !bf.cursor

    eco.dbg %r1 : i64
    // CHECK: 100
    eco.dbg %r2 : i64
    // CHECK: 200
    eco.dbg %r3 : i64
    // CHECK: 300

    // Verify sum: 100 + 200 + 300 = 600
    %sum1 = arith.addi %r1, %r2 : i64
    %sum2 = arith.addi %sum1, %r3 : i64
    eco.dbg %sum2 : i64
    // CHECK: 600

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
