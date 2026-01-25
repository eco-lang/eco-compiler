// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test bf.require succeeds when bytes are available

module {
  func.func @main() -> i64 {
    // Create buffer with 8 bytes
    %size = arith.constant 8 : i32
    %buffer = bf.alloc %size : i64
    %cursor = bf.decoder.cursor.init %buffer : i64 -> !bf.cursor

    // Require 4 bytes (should succeed)
    %req_bytes = arith.constant 4 : i32
    %ok = bf.require %cursor, %req_bytes : i1

    %ok_int = arith.extui %ok : i1 to i64
    eco.dbg %ok_int : i64
    // CHECK: 1

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
