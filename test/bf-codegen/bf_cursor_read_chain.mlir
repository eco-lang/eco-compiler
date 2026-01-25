// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test cursor threading through multiple reads

module {
  func.func @main() -> i64 {
    // Create buffer with known values
    %size = arith.constant 16 : i32
    %buffer = bf.alloc %size : i64
    %cursor0 = bf.cursor.init %buffer : i64 -> !bf.cursor

    // Write sequence 10, 20, 30, 40, 50
    %v10 = arith.constant 10 : i64
    %cursor1 = bf.write.u8 %cursor0, %v10 : !bf.cursor
    %v20 = arith.constant 20 : i64
    %cursor2 = bf.write.u8 %cursor1, %v20 : !bf.cursor
    %v30 = arith.constant 30 : i64
    %cursor3 = bf.write.u8 %cursor2, %v30 : !bf.cursor
    %v40 = arith.constant 40 : i64
    %cursor4 = bf.write.u8 %cursor3, %v40 : !bf.cursor
    %v50 = arith.constant 50 : i64
    %cursor5 = bf.write.u8 %cursor4, %v50 : !bf.cursor

    // Chain of reads - verify cursor advances correctly
    %rc0 = bf.decoder.cursor.init %buffer : i64 -> !bf.cursor
    %r1, %rc1 = bf.read.u8 %rc0 : i64, !bf.cursor
    %r2, %rc2 = bf.read.u8 %rc1 : i64, !bf.cursor
    %r3, %rc3 = bf.read.u8 %rc2 : i64, !bf.cursor
    %r4, %rc4 = bf.read.u8 %rc3 : i64, !bf.cursor
    %r5, %rc5 = bf.read.u8 %rc4 : i64, !bf.cursor

    // Sum all values
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
