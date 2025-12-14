// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test eco.get_tag operation.
// Verifies that tag extraction works correctly for ADT values.

module {
  func.func @main() -> i64 {
    %c1 = arith.constant 1 : i64
    %c2 = arith.constant 2 : i64
    %b1 = eco.box %c1 : i64 -> !eco.value
    %b2 = eco.box %c2 : i64 -> !eco.value

    // Create tagged objects with different constructor tags
    // Tag 0 = "Nothing" variant (no payload, but we include one for testing)
    %nothing = eco.construct(%b1) {tag = 0 : i64, size = 1 : i64} : (!eco.value) -> !eco.value
    // Tag 1 = "Just" variant
    %just = eco.construct(%b2) {tag = 1 : i64, size = 1 : i64} : (!eco.value) -> !eco.value
    // Tag 42 = arbitrary tag
    %custom = eco.construct(%b1) {tag = 42 : i64, size = 1 : i64} : (!eco.value) -> !eco.value

    // Extract and print tags
    %tag0 = eco.get_tag %nothing : !eco.value -> i32
    %tag1 = eco.get_tag %just : !eco.value -> i32
    %tag42 = eco.get_tag %custom : !eco.value -> i32

    // Convert to i64 for dbg
    %t0 = arith.extui %tag0 : i32 to i64
    %t1 = arith.extui %tag1 : i32 to i64
    %t42 = arith.extui %tag42 : i32 to i64

    eco.dbg %t0 : i64
    // CHECK: 0
    eco.dbg %t1 : i64
    // CHECK: 1
    eco.dbg %t42 : i64
    // CHECK: 42

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
