// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test bf.require with zero bytes (always succeeds)

module {
  func.func @main() -> i64 {
    // Create empty buffer
    %size = arith.constant 0 : i32
    %buffer = bf.alloc %size : i64
    %cursor = bf.decoder.cursor.init %buffer : !bf.cursor

    // Require 0 bytes (should succeed even on empty buffer)
    %req_bytes = arith.constant 0 : i32
    %ok = bf.require %cursor, %req_bytes : i1

    %ok_int = arith.extui %ok : i1 to i64
    eco.dbg %ok_int : i64
    // CHECK: 1

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
