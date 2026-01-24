// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test nested loop decode (list of lists conceptually)

module {
  func.func @main() -> i64 {
    // Create buffer with two groups
    // Group 1: count=2, items [1, 2]
    // Group 2: count=3, items [3, 4, 5]
    %size = arith.constant 32 : i32
    %buffer = bf.alloc %size : i64
    %c0 = bf.cursor.init %buffer : !bf.cursor

    // Outer count = 2 (two groups)
    %outer_count = arith.constant 2 : i64
    %c1 = bf.write.u32 %c0, %outer_count (le) : !bf.cursor

    // Group 1: count=2, items [1, 2]
    %g1_count = arith.constant 2 : i64
    %c2 = bf.write.u32 %c1, %g1_count (le) : !bf.cursor
    %g1_v1 = arith.constant 1 : i64
    %c3 = bf.write.u8 %c2, %g1_v1 : !bf.cursor
    %g1_v2 = arith.constant 2 : i64
    %c4 = bf.write.u8 %c3, %g1_v2 : !bf.cursor

    // Group 2: count=3, items [3, 4, 5]
    %g2_count = arith.constant 3 : i64
    %c5 = bf.write.u32 %c4, %g2_count (le) : !bf.cursor
    %g2_v1 = arith.constant 3 : i64
    %c6 = bf.write.u8 %c5, %g2_v1 : !bf.cursor
    %g2_v2 = arith.constant 4 : i64
    %c7 = bf.write.u8 %c6, %g2_v2 : !bf.cursor
    %g2_v3 = arith.constant 5 : i64
    %c8 = bf.write.u8 %c7, %g2_v3 : !bf.cursor

    // Read back
    %rc0 = bf.decoder.cursor.init %buffer : !bf.cursor
    %r_outer, %rc1 = bf.read.u32 %rc0 (le) : i64, !bf.cursor

    // Group 1
    %r_g1_count, %rc2 = bf.read.u32 %rc1 (le) : i64, !bf.cursor
    %r_g1_v1, %rc3 = bf.read.u8 %rc2 : i64, !bf.cursor
    %r_g1_v2, %rc4 = bf.read.u8 %rc3 : i64, !bf.cursor

    // Group 2
    %r_g2_count, %rc5 = bf.read.u32 %rc4 (le) : i64, !bf.cursor
    %r_g2_v1, %rc6 = bf.read.u8 %rc5 : i64, !bf.cursor
    %r_g2_v2, %rc7 = bf.read.u8 %rc6 : i64, !bf.cursor
    %r_g2_v3, %rc8 = bf.read.u8 %rc7 : i64, !bf.cursor

    eco.dbg %r_outer : i64
    // CHECK: 2
    eco.dbg %r_g1_count : i64
    // CHECK: 2
    eco.dbg %r_g2_count : i64
    // CHECK: 3

    // Sum all items: 1+2+3+4+5 = 15
    %s1 = arith.addi %r_g1_v1, %r_g1_v2 : i64
    %s2 = arith.addi %s1, %r_g2_v1 : i64
    %s3 = arith.addi %s2, %r_g2_v2 : i64
    %s4 = arith.addi %s3, %r_g2_v3 : i64
    eco.dbg %s4 : i64
    // CHECK: 15

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
