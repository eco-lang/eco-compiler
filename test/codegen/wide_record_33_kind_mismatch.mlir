// RUN: not %ecoc %s -emit=mlir 2>&1 | %FileCheck %s
//
// Phase 3B: slot_kinds must match the operand types (slot 32 is i64 = 1, attr says 2).

module {
  func.func @wide33(%b: !eco.value, %i: i64) -> !eco.value {
    %r = eco.construct.record(%b, %b, %b, %b, %b, %b, %b, %b, %b, %b, %b, %b, %b, %b, %b, %b, %b, %b, %b, %b, %b, %b, %b, %b, %b, %b, %b, %b, %b, %b, %b, %b, %i) {field_count = 33 : i64, slot_kinds = array<i8: 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2>} : (!eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, i64) -> !eco.value
    return %r : !eco.value
  }
}

// CHECK: slot_kinds[32] = 2 does not match operand type 'i64' (kind 1)
