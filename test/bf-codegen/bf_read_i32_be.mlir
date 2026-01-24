// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test bf.read.i32 signed big-endian

module {
  func.func @main() -> i64 {
    // Create buffer
    %size = arith.constant 16 : i32
    %buffer = bf.alloc %size : i64
    %cursor0 = bf.cursor.init %buffer : !bf.cursor

    // Write values that will be negative as i32
    // -1 = 0xFFFFFFFF, -2147483648 = 0x80000000
    %neg1 = arith.constant 4294967295 : i64  // 0xFFFFFFFF
    %cursor1 = bf.write.u32 %cursor0, %neg1 (be) : !bf.cursor
    %min_i32 = arith.constant 2147483648 : i64  // 0x80000000
    %cursor2 = bf.write.u32 %cursor1, %min_i32 (be) : !bf.cursor

    // Read back as signed
    %read_cursor0 = bf.decoder.cursor.init %buffer : !bf.cursor
    %r0, %read_cursor1 = bf.read.i32 %read_cursor0 (be) : i64, !bf.cursor
    %r1, %read_cursor2 = bf.read.i32 %read_cursor1 (be) : i64, !bf.cursor

    eco.dbg %r0 : i64
    // CHECK: -1
    eco.dbg %r1 : i64
    // CHECK: -2147483648

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
