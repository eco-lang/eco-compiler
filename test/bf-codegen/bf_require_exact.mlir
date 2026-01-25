// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test bf.require at exact buffer boundary

module {
  func.func @main() -> i64 {
    // Create buffer with exactly 4 bytes
    %size = arith.constant 4 : i32
    %buffer = bf.alloc %size : i64
    %cursor = bf.decoder.cursor.init %buffer : i64 -> !bf.cursor

    // Require exactly 4 bytes (should succeed)
    %req_bytes = arith.constant 4 : i32
    %ok1 = bf.require %cursor, %req_bytes : i1
    %ok1_int = arith.extui %ok1 : i1 to i64
    eco.dbg %ok1_int : i64
    // CHECK: 1

    // Require 5 bytes (should fail)
    %req_bytes5 = arith.constant 5 : i32
    %ok2 = bf.require %cursor, %req_bytes5 : i1
    %ok2_int = arith.extui %ok2 : i1 to i64
    eco.dbg %ok2_int : i64
    // CHECK: 0

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
