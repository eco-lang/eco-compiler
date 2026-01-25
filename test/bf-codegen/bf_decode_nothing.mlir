// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test failed decode returns Nothing (simulated)

module {
  func.func @main() -> i64 {
    // Create empty buffer
    %size = arith.constant 0 : i32
    %buffer = bf.alloc %size : i64

    // Try to decode with bounds check
    %rc0 = bf.decoder.cursor.init %buffer : i64 -> !bf.cursor
    %needed = arith.constant 1 : i32
    %ok = bf.require %rc0, %needed : i1

    // Fail = 0 (Nothing semantics)
    %ok_int = arith.extui %ok : i1 to i64
    eco.dbg %ok_int : i64
    // CHECK: 0

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
