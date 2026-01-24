// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test bf.alloc with zero bytes - should return valid empty buffer

module {
  func.func @main() -> i64 {
    // Allocate empty buffer (0 bytes)
    %size = arith.constant 0 : i32
    %buffer = bf.alloc %size : i64

    // Verify buffer is still a valid allocation
    %zero64 = arith.constant 0 : i64
    %is_valid = arith.cmpi ne, %buffer, %zero64 : i64
    %valid_int = arith.extui %is_valid : i1 to i64
    eco.dbg %valid_int : i64
    // CHECK: 1

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
