// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test bf.alloc with larger buffer size (64KB)

module {
  func.func @main() -> i64 {
    // Allocate larger buffer (64KB = 65536 bytes)
    // Note: Can't allocate 1MB as it exceeds nursery capacity
    %size = arith.constant 65536 : i32
    %buffer = bf.alloc %size : !eco.value

    // Verify allocation works by writing and reading back a byte
    %c0 = bf.cursor.init %buffer : !eco.value -> !bf.cursor
    %val = arith.constant 99 : i64
    %c1 = bf.write.u8 %c0, %val : !bf.cursor
    %rc0 = bf.decoder.cursor.init %buffer : !eco.value -> !bf.cursor
    %read_val, %rc1 = bf.read.u8 %rc0 : i64, !bf.cursor
    eco.dbg %read_val : i64
    // CHECK: 99

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
