// RUN: not %ecoc %s -emit=mlir 2>&1 | %FileCheck %s
//
// B14: eco.construct.record must reject i1 operands (see construct_i1_operand_rejected.mlir).

module {
  func.func @bad_record_i1(%b: i1, %x: !eco.value) -> !eco.value {
    %r = "eco.construct.record"(%b, %x) {field_count = 2 : i64, slot_kinds = array<i8: 0, 0>} : (i1, !eco.value) -> !eco.value
    return %r : !eco.value
  }
}

// CHECK: has i1 type
