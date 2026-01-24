// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test bf.alloc with larger buffer size (64KB)

module {
  func.func @main() -> i64 {
    // Allocate larger buffer (64KB = 65536 bytes)
    // Note: Can't allocate 1MB as it exceeds nursery capacity
    %size = arith.constant 65536 : i32
    %buffer = bf.alloc %size : i64

    // Verify buffer is non-zero (valid allocation)
    %zero64 = arith.constant 0 : i64
    %is_valid = arith.cmpi ne, %buffer, %zero64 : i64
    %valid_int = arith.extui %is_valid : i1 to i64
    eco.dbg %valid_int : i64
    // CHECK: 1

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
