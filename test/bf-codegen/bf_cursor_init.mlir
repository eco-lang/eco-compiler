// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test bf.cursor.init from allocated buffer

module {
  func.func @main() -> i64 {
    // Allocate buffer
    %size = arith.constant 32 : i32
    %buffer = bf.alloc %size : i64

    // Initialize cursor from buffer
    %cursor = bf.cursor.init %buffer : i64 -> !bf.cursor

    // Extract pointer - should be non-null
    %ptr = bf.cursor.ptr %cursor : i64
    %zero64 = arith.constant 0 : i64
    %is_valid = arith.cmpi ne, %ptr, %zero64 : i64
    %valid_int = arith.extui %is_valid : i1 to i64
    eco.dbg %valid_int : i64
    // CHECK: 1

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
