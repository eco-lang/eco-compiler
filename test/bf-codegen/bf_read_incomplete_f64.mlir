// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test read f64 with only 4 bytes available

module {
  func.func @main() -> i64 {
    // Create buffer with only 4 bytes
    %size = arith.constant 4 : i32
    %buffer = bf.alloc %size : i64

    %cursor = bf.decoder.cursor.init %buffer : i64 -> !bf.cursor

    // Check if we can read f64 (8 bytes) - should fail
    %needed = arith.constant 8 : i32
    %ok = bf.require %cursor, %needed : i1
    %ok_int = arith.extui %ok : i1 to i64
    eco.dbg %ok_int : i64
    // CHECK: 0

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
